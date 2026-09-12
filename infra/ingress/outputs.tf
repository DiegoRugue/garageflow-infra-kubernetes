output "deployment_outputs" {
  description = "Ingress v2 HTTP metadata. Publish only after network and listener verification."
  value = {
    listenerArn                   = aws_lb_listener.api.arn
    internalApiBaseUrl            = "http://${aws_lb.internal.dns_name}"
    transport                     = "http"
    authenticationSecurityGroupId = aws_security_group.authentication.id
    vpcLinkSecurityGroupId        = aws_security_group.vpc_link.id
  }
}
