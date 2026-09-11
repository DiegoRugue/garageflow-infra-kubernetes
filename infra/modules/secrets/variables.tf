variable "environment" {
  description = "Environment segment used in each Secrets Manager name."
  type        = string

  validation {
    condition     = contains(["homologation", "production"], var.environment)
    error_message = "environment must be homologation or production."
  }
}

variable "bootstrap_admin_email" {
  description = "Email address embedded in the bootstrap administrator secret."
  type        = string

  validation {
    condition = (
      var.bootstrap_admin_email == trimspace(var.bootstrap_admin_email) &&
      can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.bootstrap_admin_email))
    )
    error_message = "bootstrap_admin_email must be a valid email address without surrounding whitespace."
  }
}

variable "tags" {
  description = "Non-sensitive tags applied to Secrets Manager resources."
  type        = map(string)
  default     = {}
}
