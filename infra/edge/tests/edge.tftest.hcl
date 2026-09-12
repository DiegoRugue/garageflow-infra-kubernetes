mock_provider "aws" {
  mock_data "aws_apigatewayv2_api" { defaults = { execution_arn = "arn:aws:execute-api:us-east-1:123456789012:a1b2c3d4e5" } }
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_lb_listener" { defaults = { load_balancer_arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/garageflow/1234567890123456", protocol = "HTTP", port = 80 } }
  mock_data "aws_lb" { defaults = { vpc_id = "vpc-0123456789abcdef0", internal = true } }
  mock_data "aws_security_group" { defaults = { vpc_id = "vpc-0123456789abcdef0" } }
  mock_data "aws_subnet" { defaults = { vpc_id = "vpc-0123456789abcdef0", map_public_ip_on_launch = false } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/apigateway/garageflow-production" } }
}

variables {
  environment = "production"
  owner       = "garageflow-team"
  expires_on  = "2026-09-11"
  platform_contract = {
    schemaVersion = "1.0", producer = "platform", environment = "production"
    outputs = {
      awsRegion                   = "us-east-1", vpcId = "vpc-0123456789abcdef0"
      privateApplicationSubnetIds = ["subnet-0123456789abcdef0", "subnet-1123456789abcdef0"]
      apiGatewayId                = "a1b2c3d4e5", apiGatewayExecutionArn = "arn:aws:execute-api:us-east-1:123456789012:a1b2c3d4e5"
    }
  }
  ingress_contract = {
    schemaVersion = "2.0", producer = "ingress", environment = "production"
    outputs = {
      listenerArn                   = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/garageflow/1234567890123456/1234567890123456"
      internalApiBaseUrl            = "http://internal.example.com", transport = "http"
      authenticationSecurityGroupId = "sg-0123456789abcdef0", vpcLinkSecurityGroupId = "sg-1123456789abcdef0"
    }
  }
  serverless_contract = {
    schemaVersion = "1.0", producer = "serverless", environment = "production"
    outputs = {
      customerAuthenticationAliasArn = "arn:aws:lambda:us-east-1:123456789012:function:garageflow-production-auth:live"
      requestAuthorizerAliasArn      = "arn:aws:lambda:us-east-1:123456789012:function:garageflow-production-authorizer:live"
    }
  }
}

run "explicit_authorized_routes" {
  command = apply
  assert {
    condition     = aws_apigatewayv2_authorizer.users.authorizer_result_ttl_in_seconds == 0 && aws_apigatewayv2_authorizer.users.enable_simple_responses && aws_apigatewayv2_authorizer.users.authorizer_payload_format_version == "2.0"
    error_message = "Validate every request with the simple-response authorizer."
  }
  assert {
    condition     = aws_apigatewayv2_integration.api.request_parameters["overwrite:path"] == "$request.path" && aws_apigatewayv2_integration.api.connection_type == "VPC_LINK" && aws_apigatewayv2_integration.api.payload_format_version == "1.0"
    error_message = "Private integration must preserve the application's route path."
  }
  assert {
    condition     = aws_apigatewayv2_route.routes["POST /auth/customers/token"].authorization_type == "NONE" && aws_apigatewayv2_route.routes["PUT /users/me/password"].authorization_type == "CUSTOM" && aws_apigatewayv2_route.routes["GET /me/work-orders"].authorization_type == "CUSTOM"
    error_message = "Login is public; customer orders and password change require a validated user JWT."
  }
  assert {
    condition     = length(aws_apigatewayv2_route.routes) == 65 && alltrue([for key in keys(aws_apigatewayv2_route.routes) : !can(regex("internal|health|\\$default|\\+|openapi|scalar", key))])
    error_message = "Expose only the reviewed explicit public and business route catalog."
  }
  assert {
    condition     = aws_apigatewayv2_stage.live.name == "$default" && aws_apigatewayv2_stage.live.auto_deploy && aws_apigatewayv2_stage.live.default_route_settings[0].throttling_rate_limit == 20
    error_message = "Use the managed HTTPS endpoint with bounded request rates."
  }
}

run "reject_wrong_ingress_environment" {
  command = plan
  variables { environment = "homologation" }
  expect_failures = [var.platform_contract, var.ingress_contract, var.serverless_contract]
}

run "reject_public_load_balancer" {
  command = plan
  override_data {
    target = data.aws_lb.internal
    values = { vpc_id = "vpc-0123456789abcdef0", internal = false }
  }
  expect_failures = [terraform_data.contract_identity]
}

run "reject_wrong_account" {
  command = plan
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "999999999999" }
  }
  expect_failures = [terraform_data.contract_identity]
}
