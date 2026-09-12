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
  description = "Validated platform v1 metadata; no remote state or secret values."
  type = object({
    schemaVersion = string
    producer      = string
    environment   = string
    outputs = object({
      awsRegion                   = string
      vpcId                       = string
      privateApplicationSubnetIds = list(string)
      clusterName                 = string
      clusterSecurityGroupId      = string
      apiGatewayExecutionArn      = string
    })
  })
  validation {
    condition = (
      var.platform_contract.schemaVersion == "1.0" && var.platform_contract.producer == "platform" &&
      var.platform_contract.environment == var.environment && var.platform_contract.outputs.awsRegion == "us-east-1" &&
      length(distinct(var.platform_contract.outputs.privateApplicationSubnetIds)) >= 2 &&
      can(regex("^arn:aws:execute-api:us-east-1:[0-9]{12}:[a-z0-9]+$", var.platform_contract.outputs.apiGatewayExecutionArn))
    )
    error_message = "A matching us-east-1 platform v1 contract with two private application subnets is required."
  }
}
