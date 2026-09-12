mock_provider "aws" {
  mock_resource "aws_lb" { defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/garageflow/1234567890123456" } }
  mock_resource "aws_lb_target_group" { defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/garageflow/1234567890123456" } }
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_vpc" { defaults = { cidr_block = "10.42.0.0/16" } }
  mock_data "aws_subnet" { defaults = { vpc_id = "vpc-0123456789abcdef0", map_public_ip_on_launch = false } }
  mock_data "aws_security_group" { defaults = { vpc_id = "vpc-0123456789abcdef0" } }
  mock_data "aws_eks_cluster" { defaults = { vpc_config = [{ vpc_id = "vpc-0123456789abcdef0", cluster_security_group_id = "sg-0123456789abcdef0" }] } }
  mock_data "aws_eks_node_group" {
    defaults = { resources = [{ autoscaling_groups = [{ name = "garageflow-workers" }] }] }
  }
}

variables {
  environment = "homologation"
  owner       = "garageflow-team"
  expires_on  = "2026-09-11"
  platform_contract = {
    schemaVersion = "1.0", producer = "platform", environment = "homologation"
    outputs = {
      awsRegion                   = "us-east-1", vpcId = "vpc-0123456789abcdef0"
      privateApplicationSubnetIds = ["subnet-0123456789abcdef0", "subnet-1123456789abcdef0"]
      clusterName                 = "garageflow-homologation", clusterSecurityGroupId = "sg-0123456789abcdef0"
      apiGatewayExecutionArn      = "arn:aws:execute-api:us-east-1:123456789012:a1b2c3d4e5"
    }
  }
}

run "private_http_topology" {
  command = apply
  assert {
    condition     = aws_lb.internal.internal && aws_lb_listener.api.protocol == "HTTP" && aws_lb_listener.api.port == 80
    error_message = "Academy ingress must be an internal ALB with HTTP listener."
  }
  assert {
    condition     = aws_lb_target_group.api.port == 30080 && aws_lb_target_group.api.target_type == "instance" && aws_lb_target_group.api.health_check[0].path == "/health/ready"
    error_message = "Traffic and readiness must reach the application's restricted NodePort."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.from_authentication.referenced_security_group_id == aws_security_group.authentication.id && aws_vpc_security_group_ingress_rule.from_gateway.referenced_security_group_id == aws_security_group.vpc_link.id
    error_message = "Only authentication Lambda and VPC Link may enter the ALB."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.nodeport.referenced_security_group_id == aws_security_group.alb.id && aws_vpc_security_group_ingress_rule.nodeport.security_group_id == var.platform_contract.outputs.clusterSecurityGroupId && aws_vpc_security_group_ingress_rule.nodeport.from_port == 30080
    error_message = "NodePort must accept ALB traffic only."
  }
  assert {
    condition     = keys(aws_autoscaling_attachment.workers) == ["garageflow-workers"] && output.deployment_outputs.transport == "http" && !contains(keys(output.deployment_outputs), "tlsServerName")
    error_message = "Workers must be registered and HTTP metadata must not promise TLS."
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.authentication_secrets.cidr_ipv4 == "10.42.0.0/16" && aws_vpc_security_group_egress_rule.authentication_secrets.to_port == 443
    error_message = "Lambda must reach the private Secrets Manager endpoint without unrestricted egress."
  }
}

run "reject_cross_environment" {
  command = plan
  variables { environment = "production" }
  expect_failures = [var.platform_contract]
}

run "reject_wrong_account" {
  command = plan
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "999999999999" }
  }
  expect_failures = [terraform_data.contract_identity]
}

run "reject_wrong_vpc" {
  command = plan
  override_data {
    target = data.aws_security_group.nodes
    values = { vpc_id = "vpc-99999999999999999" }
  }
  expect_failures = [terraform_data.contract_identity]
}
