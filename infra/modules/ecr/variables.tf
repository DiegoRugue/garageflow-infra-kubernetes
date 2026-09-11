variable "repository_name" {
  description = "Environment-qualified ECR repository name."
  type        = string

  validation {
    condition = (
      length(var.repository_name) >= 2 &&
      length(var.repository_name) <= 256 &&
      can(regex("^[a-z0-9]+(?:[._/-][a-z0-9]+)*$", var.repository_name))
    )
    error_message = "repository_name must be a valid ECR repository name."
  }
}

variable "tags" {
  description = "Non-sensitive tags applied to the ECR repository."
  type        = map(string)
  default     = {}
}
