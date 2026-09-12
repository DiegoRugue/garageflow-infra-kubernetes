locals {
  platform   = var.platform_contract.outputs
  ingress    = var.ingress_contract.outputs
  serverless = var.serverless_contract.outputs
  routes     = jsondecode(file("${path.module}/routes.json"))
  tags = {
    Project   = "GarageFlow", Environment = var.environment, Owner = var.owner
    ExpiresOn = var.expires_on, ManagedBy = "Terraform", Component = "edge"
  }
}

data "aws_caller_identity" "current" {}
data "aws_apigatewayv2_api" "platform" { api_id = local.platform.apiGatewayId }
data "aws_lb_listener" "api" { arn = local.ingress.listenerArn }
data "aws_lb" "internal" { arn = data.aws_lb_listener.api.load_balancer_arn }
data "aws_security_group" "vpc_link" { id = local.ingress.vpcLinkSecurityGroupId }
data "aws_subnet" "application" {
  for_each = toset(local.platform.privateApplicationSubnetIds)
  id       = each.value
}
resource "terraform_data" "contract_identity" {
  lifecycle {
    precondition {
      condition = alltrue([for arn in [local.platform.apiGatewayExecutionArn, local.ingress.listenerArn, local.serverless.customerAuthenticationAliasArn, local.serverless.requestAuthorizerAliasArn] :
        try(split(":", arn)[4] == data.aws_caller_identity.current.account_id && split(":", arn)[3] == "us-east-1", false)
      ]) && data.aws_apigatewayv2_api.platform.execution_arn == local.platform.apiGatewayExecutionArn
      error_message = "All edge resources must belong to the caller's AWS account and region."
    }
    precondition {
      condition = (
        data.aws_lb.internal.internal && data.aws_lb.internal.vpc_id == local.platform.vpcId &&
        data.aws_security_group.vpc_link.vpc_id == local.platform.vpcId &&
        alltrue([for subnet in data.aws_subnet.application : subnet.vpc_id == local.platform.vpcId && !subnet.map_public_ip_on_launch]) &&
        lower(data.aws_lb_listener.api.protocol) == local.ingress.transport
      )
      error_message = "Ingress and VPC Link must use the platform private network and declared listener transport."
    }
  }
}

resource "aws_apigatewayv2_vpc_link" "api" {
  name               = "garageflow-${var.environment}"
  security_group_ids = [local.ingress.vpcLinkSecurityGroupId]
  subnet_ids         = local.platform.privateApplicationSubnetIds
  tags               = local.tags
  depends_on         = [terraform_data.contract_identity]
}

resource "aws_apigatewayv2_integration" "api" {
  api_id                 = local.platform.apiGatewayId
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = local.ingress.listenerArn
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.api.id
  payload_format_version = "1.0"
  timeout_milliseconds   = 29000
  request_parameters     = { "overwrite:path" = "$request.path" }
  dynamic "tls_config" {
    for_each = local.ingress.transport == "https" ? [local.ingress.tlsServerName] : []
    content { server_name_to_verify = tls_config.value }
  }
}

resource "aws_apigatewayv2_integration" "authentication" {
  api_id                 = local.platform.apiGatewayId
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/${local.serverless.customerAuthenticationAliasArn}/invocations"
  payload_format_version = "2.0"
  timeout_milliseconds   = 12000
  depends_on             = [terraform_data.contract_identity]
}

resource "aws_apigatewayv2_authorizer" "users" {
  api_id                            = local.platform.apiGatewayId
  name                              = "garageflow-user-jwt"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/${local.serverless.requestAuthorizerAliasArn}/invocations"
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  authorizer_result_ttl_in_seconds  = 0
  identity_sources                  = ["$request.header.Authorization"]
  depends_on                        = [terraform_data.contract_identity]
}

resource "aws_apigatewayv2_route" "routes" {
  for_each           = local.routes
  api_id             = local.platform.apiGatewayId
  route_key          = each.key
  target             = "integrations/${each.value.integration == "api" ? aws_apigatewayv2_integration.api.id : aws_apigatewayv2_integration.authentication.id}"
  authorization_type = each.value.authorization
  authorizer_id      = each.value.authorization == "CUSTOM" ? aws_apigatewayv2_authorizer.users.id : null
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/garageflow-${var.environment}"
  retention_in_days = 7
  tags              = local.tags
  depends_on        = [terraform_data.contract_identity]
}

resource "aws_apigatewayv2_stage" "live" {
  api_id      = local.platform.apiGatewayId
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    detailed_metrics_enabled = true
    throttling_rate_limit    = 20
    throttling_burst_limit   = 40
  }
  dynamic "route_settings" {
    for_each = toset(["POST /auth/login", "POST /auth/customers/token"])
    content {
      route_key              = route_settings.value
      throttling_rate_limit  = 5
      throttling_burst_limit = 10
    }
  }
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId = "$context.requestId", routeKey = "$context.routeKey"
      status    = "$context.status", latency = "$context.responseLatency"
    })
  }
  tags       = local.tags
  depends_on = [aws_apigatewayv2_route.routes]
}
