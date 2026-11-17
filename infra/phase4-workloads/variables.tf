variable "environment" {
  type        = string
  description = "The GarageFlow environment that owns the workload resources."

  validation {
    condition     = contains(["homologation", "production"], var.environment)
    error_message = "Use homologation or production."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region of the existing GarageFlow platform."
  default     = "us-east-1"
}

variable "aws_account_id" {
  type        = string
  description = "Expected AWS account ID for this environment."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Use a 12-digit AWS account ID."
  }
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name from the platform contract for this environment."
}

variable "workload_role_arns" {
  type = object({
    api       = string
    execution = string
    billing   = string
  })
  description = "Existing IAM roles that trust pods.eks.amazonaws.com and are dedicated to these workloads."

  validation {
    condition = length(toset(values(var.workload_role_arns))) == 3 && alltrue([
      for role in values(var.workload_role_arns) :
      can(regex("^arn:aws:iam::${var.aws_account_id}:role/[^[:space:]]+$", role))
    ])
    error_message = "Provide three distinct IAM role ARNs from the expected AWS account."
  }
}
