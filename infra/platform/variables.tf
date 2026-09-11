variable "environment" {
  description = "Deployment environment selected from the protected branch."
  type        = string

  validation {
    condition     = contains(["homologation", "production"], var.environment)
    error_message = "environment must be homologation or production."
  }
}

variable "aws_region" {
  description = "AWS region approved for the GarageFlow Academy deployment."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "aws_region must be us-east-1."
  }
}

variable "owner" {
  description = "Nonempty owner tag for the temporary Academy resources."
  type        = string

  validation {
    condition     = trimspace(var.owner) != "" && var.owner == trimspace(var.owner)
    error_message = "owner must be nonempty and must not contain surrounding whitespace."
  }
}

variable "expires_on" {
  description = "ISO calendar date recording the intended Academy cleanup."
  type        = string

  validation {
    condition = (
      can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", var.expires_on)) &&
      can(formatdate("YYYY-MM-DD", "${var.expires_on}T00:00:00Z"))
    )
    error_message = "expires_on must be a valid ISO date in YYYY-MM-DD format."
  }
}

variable "eks_cluster_role_arn" {
  description = "ARN of the pre-existing Academy role used by the EKS control plane."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z0-9-]+:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]*[A-Za-z0-9+=,.@_-]$", var.eks_cluster_role_arn))
    error_message = "eks_cluster_role_arn must be a syntactically valid IAM role ARN."
  }
}

variable "eks_node_role_arn" {
  description = "ARN of the pre-existing Academy role used by the EKS managed node group."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z0-9-]+:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]*[A-Za-z0-9+=,.@_-]$", var.eks_node_role_arn))
    error_message = "eks_node_role_arn must be a syntactically valid IAM role ARN."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version; deployment preflight requires STANDARD_SUPPORT."
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must use major.minor notation, for example 1.36."
  }
}

variable "bootstrap_admin_email" {
  description = "Administrator email stored in the bootstrap secret."
  type        = string

  validation {
    condition = (
      var.bootstrap_admin_email == trimspace(var.bootstrap_admin_email) &&
      can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.bootstrap_admin_email))
    )
    error_message = "bootstrap_admin_email must be a valid email address without surrounding whitespace."
  }
}

variable "notification_email" {
  description = "Email endpoint that manually confirms the SNS subscription."
  type        = string

  validation {
    condition = (
      var.notification_email == trimspace(var.notification_email) &&
      can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.notification_email))
    )
    error_message = "notification_email must be a valid email address without surrounding whitespace."
  }
}

variable "public_access_cidrs" {
  description = "Distinct IPv4 CIDRs allowed to reach the public EKS API endpoint."
  type        = list(string)

  validation {
    condition = (
      length(var.public_access_cidrs) > 0 &&
      length(distinct(var.public_access_cidrs)) == length(var.public_access_cidrs) &&
      alltrue([
        for cidr in var.public_access_cidrs :
        cidr == trimspace(cidr) && can(cidrnetmask(cidr)) && can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$", cidr))
      ])
    )
    error_message = "public_access_cidrs must contain one or more distinct IPv4 CIDR blocks without surrounding whitespace."
  }
}
