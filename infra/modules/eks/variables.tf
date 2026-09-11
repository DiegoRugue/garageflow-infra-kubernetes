variable "cluster_name" {
  description = "Environment-qualified EKS cluster name."
  type        = string

  validation {
    condition     = can(regex("^garageflow-(homologation|production)$", var.cluster_name))
    error_message = "cluster_name must be garageflow-homologation or garageflow-production."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes control-plane version."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must use major.minor notation."
  }
}

variable "public_subnet_ids" {
  description = "Two distinct public worker subnet IDs."
  type        = list(string)

  validation {
    condition = (
      length(var.public_subnet_ids) == 2 &&
      length(distinct(var.public_subnet_ids)) == 2 &&
      alltrue([for subnet_id in var.public_subnet_ids : can(regex("^subnet-[0-9a-fA-F]+$", subnet_id))])
    )
    error_message = "public_subnet_ids must contain exactly two distinct subnet IDs."
  }
}

variable "cluster_role_arn" {
  description = "Pre-existing role ARN used by the EKS control plane."
  type        = string
}

variable "node_role_arn" {
  description = "Pre-existing role ARN used by the managed node group."
  type        = string
}

variable "public_access_cidrs" {
  description = "IPv4 CIDRs allowed to reach the public EKS API endpoint."
  type        = list(string)
}

variable "tags" {
  description = "Non-sensitive tags applied to EKS resources."
  type        = map(string)
  default     = {}
}
