variable "topic_name" {
  description = "Environment-qualified standard SNS topic name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,256}$", var.topic_name))
    error_message = "topic_name must be a valid standard SNS topic name."
  }
}

variable "notification_email" {
  description = "Email address that must manually confirm the SNS subscription."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.notification_email))
    error_message = "notification_email must be a valid email address."
  }
}

variable "tags" {
  description = "Non-sensitive tags applied to SNS resources."
  type        = map(string)
  default     = {}
}
