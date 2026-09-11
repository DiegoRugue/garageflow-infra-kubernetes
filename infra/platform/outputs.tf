output "deployment_outputs" {
  description = "Public metadata contract input published by deployment automation."
  value = {
    awsRegion                   = var.aws_region
    vpcId                       = module.network.vpc_id
    publicSubnetIds             = module.network.public_subnet_ids
    privateApplicationSubnetIds = module.network.private_application_subnet_ids
    databaseSubnetIds           = module.network.database_subnet_ids
    clusterName                 = module.eks.cluster_name
    clusterSecurityGroupId      = module.eks.cluster_security_group_id
    ecrRepositoryUrl            = module.ecr.repository_url
    apiGatewayId                = aws_apigatewayv2_api.this.id
    apiGatewayExecutionArn      = aws_apigatewayv2_api.this.execution_arn
    jwtSecretArn                = module.secrets.jwt_secret_arn
    internalAuthSecretArn       = module.secrets.internal_auth_secret_arn
    bootstrapSecretArn          = module.secrets.bootstrap_secret_arn
    webhookSecretArn            = module.secrets.webhook_secret_arn
    snsTopicArn                 = module.sns.topic_arn
  }
}

output "platform_design" {
  description = "Non-sensitive topology metadata used by offline policy tests."
  value = {
    resourceName                    = local.resource_name
    vpcCidr                         = module.network.vpc_cidr
    privateApplicationRouteTableIds = module.network.private_application_route_table_ids
    databaseRouteTableIds           = module.network.database_route_table_ids
    secretsManagerEndpointId        = module.network.secrets_manager_endpoint_id
    secretsManagerPrivateDnsEnabled = module.network.secrets_manager_private_dns_enabled
    nodeGroupName                   = module.eks.node_group_name
    nodeInstanceTypes               = module.eks.node_instance_types
    nodeDesiredSize                 = module.eks.node_desired_size
  }
}
