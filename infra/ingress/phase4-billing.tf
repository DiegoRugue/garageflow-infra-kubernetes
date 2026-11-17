locals {
  billing_webhook_path = "/webhooks/mercado-pago/orders"
  billing_nodeport     = 30081
}

resource "aws_vpc_security_group_ingress_rule" "billing_nodeport" {
  count = var.phase4_enabled ? 1 : 0

  security_group_id            = local.platform.clusterSecurityGroupId
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.billing_nodeport
  to_port                      = local.billing_nodeport
  tags                         = local.tags
}

resource "aws_vpc_security_group_egress_rule" "alb_billing_nodes" {
  count = var.phase4_enabled ? 1 : 0

  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = local.platform.clusterSecurityGroupId
  ip_protocol                  = "tcp"
  from_port                    = local.billing_nodeport
  to_port                      = local.billing_nodeport
  tags                         = local.tags
}

resource "aws_lb_target_group" "billing" {
  count = var.phase4_enabled ? 1 : 0

  name        = "gf-${var.environment}-billing"
  port        = local.billing_nodeport
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = local.platform.vpcId
  health_check {
    path                = "/health/live"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
  tags       = local.tags
  depends_on = [terraform_data.contract_identity]
}

resource "aws_lb_listener_rule" "billing_webhook" {
  count = var.phase4_enabled ? 1 : 0

  listener_arn = aws_lb_listener.api.arn
  priority     = 100
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.billing[0].arn
  }
  condition {
    path_pattern { values = [local.billing_webhook_path] }
  }
  condition {
    http_request_method { values = ["POST"] }
  }
  tags = local.tags
}

resource "aws_autoscaling_attachment" "billing_workers" {
  for_each = {
    for name, worker in aws_autoscaling_attachment.workers : name => worker.autoscaling_group_name
    if var.phase4_enabled
  }

  autoscaling_group_name = each.value
  lb_target_group_arn    = aws_lb_target_group.billing[0].arn
}
