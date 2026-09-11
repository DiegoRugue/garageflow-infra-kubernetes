data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  resource_name      = "garageflow-${var.environment}"
  availability_zones = slice(sort(data.aws_availability_zones.available.names), 0, 2)
  vpc_cidrs = {
    homologation = "10.42.0.0/16"
    production   = "10.43.0.0/16"
  }
  default_tags = {
    Project     = "GarageFlow"
    Phase       = "3"
    Environment = var.environment
    Owner       = var.owner
    ExpiresOn   = var.expires_on
    ManagedBy   = "Terraform"
  }
}

module "network" {
  source = "../modules/network"

  availability_zones = local.availability_zones
  cluster_name       = local.resource_name
  vpc_cidr           = local.vpc_cidrs[var.environment]
  aws_region         = var.aws_region
  tags               = local.default_tags
}

module "secrets" {
  source = "../modules/secrets"

  environment           = var.environment
  bootstrap_admin_email = var.bootstrap_admin_email
  tags                  = local.default_tags
}

module "eks" {
  source = "../modules/eks"

  cluster_name        = local.resource_name
  kubernetes_version  = var.kubernetes_version
  public_subnet_ids   = module.network.public_subnet_ids
  cluster_role_arn    = var.eks_cluster_role_arn
  node_role_arn       = var.eks_node_role_arn
  public_access_cidrs = var.public_access_cidrs
  tags                = local.default_tags
}

module "ecr" {
  source = "../modules/ecr"

  repository_name = local.resource_name
  tags            = local.default_tags
}

module "sns" {
  source = "../modules/sns"

  topic_name         = "${local.resource_name}-work-orders"
  notification_email = var.notification_email
  tags               = local.default_tags
}

resource "aws_apigatewayv2_api" "this" {
  name          = local.resource_name
  protocol_type = "HTTP"
  description   = "GarageFlow ${var.environment} HTTP API; routes are owned by the later edge root."
  tags          = local.default_tags
}
