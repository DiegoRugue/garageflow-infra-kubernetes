locals {
  platform = var.platform_contract.outputs
  tags = {
    Project   = "GarageFlow", Environment = var.environment, Owner = var.owner
    ExpiresOn = var.expires_on, ManagedBy = "Terraform", Component = "ingress"
  }
}

data "aws_caller_identity" "current" {}
data "aws_vpc" "platform" { id = local.platform.vpcId }
data "aws_subnet" "application" {
  for_each = toset(local.platform.privateApplicationSubnetIds)
  id       = each.value
}
data "aws_security_group" "nodes" { id = local.platform.clusterSecurityGroupId }
data "aws_eks_cluster" "platform" { name = local.platform.clusterName }
data "aws_eks_node_group" "workers" {
  cluster_name    = local.platform.clusterName
  node_group_name = "${local.platform.clusterName}-workers"
}

resource "terraform_data" "contract_identity" {
  lifecycle {
    precondition {
      condition     = split(":", local.platform.apiGatewayExecutionArn)[4] == data.aws_caller_identity.current.account_id
      error_message = "Platform contract belongs to another AWS account."
    }
    precondition {
      condition = (
        data.aws_security_group.nodes.vpc_id == local.platform.vpcId &&
        data.aws_eks_cluster.platform.vpc_config[0].vpc_id == local.platform.vpcId &&
        data.aws_eks_cluster.platform.vpc_config[0].cluster_security_group_id == local.platform.clusterSecurityGroupId &&
        alltrue([for subnet in data.aws_subnet.application : subnet.vpc_id == local.platform.vpcId && !subnet.map_public_ip_on_launch])
      )
      error_message = "EKS, node security group and private application subnets must belong to the platform VPC."
    }
  }
}

resource "aws_security_group" "authentication" {
  name_prefix = "gf-${var.environment}-auth-"
  description = "Customer authentication Lambda private access"
  vpc_id      = local.platform.vpcId
  tags        = local.tags
  depends_on  = [terraform_data.contract_identity]
}

resource "aws_security_group" "vpc_link" {
  name_prefix = "gf-${var.environment}-link-"
  description = "API Gateway VPC Link private access"
  vpc_id      = local.platform.vpcId
  tags        = local.tags
  depends_on  = [terraform_data.contract_identity]
}

resource "aws_security_group" "alb" {
  name_prefix = "gf-${var.environment}-alb-"
  description = "Internal API load balancer"
  vpc_id      = local.platform.vpcId
  tags        = local.tags
  depends_on  = [terraform_data.contract_identity]
}

resource "aws_vpc_security_group_ingress_rule" "from_authentication" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.authentication.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  tags                         = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "from_gateway" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.vpc_link.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  tags                         = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "nodeport" {
  security_group_id            = local.platform.clusterSecurityGroupId
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 30080
  to_port                      = 30080
  tags                         = local.tags
}

resource "aws_vpc_security_group_egress_rule" "authentication_api" {
  security_group_id            = aws_security_group.authentication.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  tags                         = local.tags
}

resource "aws_vpc_security_group_egress_rule" "authentication_secrets" {
  security_group_id = aws_security_group.authentication.id
  cidr_ipv4         = data.aws_vpc.platform.cidr_block
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  tags              = local.tags
}

resource "aws_vpc_security_group_egress_rule" "gateway_api" {
  security_group_id            = aws_security_group.vpc_link.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  tags                         = local.tags
}

resource "aws_vpc_security_group_egress_rule" "alb_nodes" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = local.platform.clusterSecurityGroupId
  ip_protocol                  = "tcp"
  from_port                    = 30080
  to_port                      = 30080
  tags                         = local.tags
}

resource "aws_lb" "internal" {
  name                       = "gf-${var.environment}-internal"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = local.platform.privateApplicationSubnetIds
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  tags                       = local.tags
}

resource "aws_lb_target_group" "api" {
  name        = "gf-${var.environment}-api"
  port        = 30080
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = local.platform.vpcId
  health_check {
    path                = "/health/ready"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
  tags       = local.tags
  depends_on = [terraform_data.contract_identity]
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
  tags = local.tags
}

resource "aws_autoscaling_attachment" "workers" {
  for_each               = toset(flatten([for resource in data.aws_eks_node_group.workers.resources : [for group in resource.autoscaling_groups : group.name]]))
  autoscaling_group_name = each.value
  lb_target_group_arn    = aws_lb_target_group.api.arn
}
