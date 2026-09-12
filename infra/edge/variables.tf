variable "environment" {
  type = string
  validation {
    condition     = contains(["homologation", "production"], var.environment)
    error_message = "environment must be homologation or production."
  }
}
variable "owner" {
  type = string
  validation {
    condition     = trimspace(var.owner) != ""
    error_message = "owner must be nonempty."
  }
}
variable "expires_on" {
  type = string
  validation {
    condition     = can(formatdate("YYYY-MM-DD", "${var.expires_on}T00:00:00Z"))
    error_message = "expires_on must be an ISO calendar date."
  }
}
variable "platform_contract" {
  type = object({
    schemaVersion = string, producer = string, environment = string
    outputs = object({
      awsRegion    = string, vpcId = string, privateApplicationSubnetIds = list(string)
      apiGatewayId = string, apiGatewayExecutionArn = string
    })
  })
  validation {
    condition = (
      var.platform_contract.schemaVersion == "1.0" && var.platform_contract.producer == "platform" &&
      var.platform_contract.environment == var.environment && var.platform_contract.outputs.awsRegion == "us-east-1" &&
      length(distinct(var.platform_contract.outputs.privateApplicationSubnetIds)) >= 2 &&
      can(regex("^arn:aws:execute-api:us-east-1:[0-9]{12}:${var.platform_contract.outputs.apiGatewayId}$", var.platform_contract.outputs.apiGatewayExecutionArn))
    )
    error_message = "A matching us-east-1 platform v1 contract is required."
  }
}
variable "ingress_contract" {
  type = object({
    schemaVersion = string, producer = string, environment = string
    outputs = object({
      listenerArn                   = string, internalApiBaseUrl = string, transport = string
      authenticationSecurityGroupId = string, vpcLinkSecurityGroupId = string
      tlsServerName                 = optional(string)
    })
  })
  validation {
    condition = (
      var.ingress_contract.schemaVersion == "2.0" && var.ingress_contract.producer == "ingress" &&
      var.ingress_contract.environment == var.environment &&
      contains(["http", "https"], var.ingress_contract.outputs.transport) &&
      (var.ingress_contract.outputs.transport == "https" ? var.ingress_contract.outputs.tlsServerName != null : var.ingress_contract.outputs.tlsServerName == null)
    )
    error_message = "A matching ingress v2 contract with explicit transport is required."
  }
}
variable "serverless_contract" {
  type = object({
    schemaVersion = string, producer = string, environment = string
    outputs       = object({ customerAuthenticationAliasArn = string, requestAuthorizerAliasArn = string })
  })
  validation {
    condition = (
      var.serverless_contract.schemaVersion == "1.0" && var.serverless_contract.producer == "serverless" &&
      var.serverless_contract.environment == var.environment &&
      alltrue([for arn in [var.serverless_contract.outputs.customerAuthenticationAliasArn, var.serverless_contract.outputs.requestAuthorizerAliasArn] : can(regex("^arn:aws:lambda:us-east-1:[0-9]{12}:function:[A-Za-z0-9_-]+:live$", arn))])
    )
    error_message = "A matching serverless v1 contract identifying live Lambda aliases is required."
  }
}
