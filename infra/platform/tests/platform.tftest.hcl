mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b"]
    }
  }
}

mock_provider "random" {}

variables {
  environment           = "homologation"
  owner                 = "garageflow-team"
  expires_on            = "2026-09-11"
  eks_cluster_role_arn  = "arn:aws:iam::123456789012:role/LabRole"
  eks_node_role_arn     = "arn:aws:iam::123456789012:role/LabRole"
  bootstrap_admin_email = "admin@example.com"
  notification_email    = "alerts@example.com"
  public_access_cidrs   = ["203.0.113.10/32"]
}

run "homologation_platform_contract" {
  command = plan

  assert {
    condition = toset(keys(output.deployment_outputs)) == toset([
      "awsRegion",
      "vpcId",
      "publicSubnetIds",
      "privateApplicationSubnetIds",
      "databaseSubnetIds",
      "clusterName",
      "clusterSecurityGroupId",
      "ecrRepositoryUrl",
      "apiGatewayId",
      "apiGatewayExecutionArn",
      "jwtSecretArn",
      "internalAuthSecretArn",
      "bootstrapSecretArn",
      "webhookSecretArn",
      "snsTopicArn",
    ])
    error_message = "deployment_outputs must expose the exact platform metadata contract."
  }

  assert {
    condition = (
      output.deployment_outputs.awsRegion == "us-east-1" &&
      output.deployment_outputs.clusterName == "garageflow-homologation" &&
      length(output.deployment_outputs.publicSubnetIds) == 2 &&
      length(output.deployment_outputs.privateApplicationSubnetIds) == 2 &&
      length(output.deployment_outputs.databaseSubnetIds) == 2
    )
    error_message = "The platform contract must contain region, isolated cluster name, and all three two-AZ subnet classes."
  }

  assert {
    condition = (
      output.platform_design.resourceName == "garageflow-homologation" &&
      output.platform_design.vpcCidr == "10.42.0.0/16" &&
      length(output.platform_design.privateApplicationRouteTableIds) == 2 &&
      length(output.platform_design.databaseRouteTableIds) == 2
    )
    error_message = "Homologation must use its CIDR and explicit route tables for each private subnet."
  }

  assert {
    condition = (
      output.platform_design.secretsManagerPrivateDnsEnabled &&
      output.platform_design.nodeDesiredSize == 2 &&
      output.platform_design.nodeInstanceTypes == tolist(["t3.small"])
    )
    error_message = "Private Secrets Manager DNS and the two-node t3.small EKS shape are required."
  }

  assert {
    condition = (
      aws_apigatewayv2_api.this.protocol_type == "HTTP" &&
      aws_apigatewayv2_api.this.name == "garageflow-homologation" &&
      aws_apigatewayv2_api.this.tags["Phase"] == "3"
    )
    error_message = "The platform root must own an environment-qualified empty HTTP API tagged for Phase 3."
  }

  assert {
    condition = toset(module.secrets.secret_names) == toset([
      "garageflow/homologation/jwt",
      "garageflow/homologation/internal-auth",
      "garageflow/homologation/bootstrap",
      "garageflow/homologation/webhook",
    ])
    error_message = "Platform secret ownership must be exact and must exclude database credentials."
  }
}

run "production_is_isolated" {
  command = plan

  variables {
    environment = "production"
  }

  assert {
    condition = (
      output.platform_design.resourceName == "garageflow-production" &&
      output.platform_design.vpcCidr == "10.43.0.0/16" &&
      output.deployment_outputs.clusterName == "garageflow-production" &&
      aws_apigatewayv2_api.this.name == "garageflow-production" &&
      module.ecr.repository_name == "garageflow-production" &&
      module.sns.topic_name == "garageflow-production-work-orders"
    )
    error_message = "Production names and CIDR must be isolated from homologation."
  }
}

run "unsupported_environment_is_rejected" {
  command = plan

  variables {
    environment = "academy"
  }

  expect_failures = [var.environment]
}
