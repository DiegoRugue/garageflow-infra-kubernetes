variable "availability_zones" {
  description = "Two distinct availability zones in the configured region."
  type        = list(string)

  validation {
    condition = (
      length(var.availability_zones) == 2 &&
      length(distinct([for az in var.availability_zones : trimspace(az)])) == 2 &&
      alltrue([for az in var.availability_zones : az == trimspace(az) && can(regex("^([a-z]{2}(-[a-z0-9]+)+-[0-9]+)[a-z]$", az))])
    )
    error_message = "availability_zones must contain exactly two distinct standard availability zones."
  }
}

variable "cluster_name" {
  description = "Environment-qualified cluster name used in resource names and Kubernetes tags."
  type        = string

  validation {
    condition     = can(regex("^garageflow-(homologation|production)$", var.cluster_name))
    error_message = "cluster_name must be garageflow-homologation or garageflow-production."
  }
}

variable "vpc_cidr" {
  description = "Environment-specific /16 VPC CIDR."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && can(regex("^10\\.[0-9]{1,3}\\.0\\.0/16$", var.vpc_cidr))
    error_message = "vpc_cidr must be a valid private 10.x.0.0/16 CIDR."
  }
}

variable "aws_region" {
  description = "AWS region used to build the Secrets Manager endpoint service name."
  type        = string

  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "aws_region must be us-east-1."
  }
}

variable "tags" {
  description = "Non-sensitive tags applied to network resources."
  type        = map(string)
  default     = {}
}
