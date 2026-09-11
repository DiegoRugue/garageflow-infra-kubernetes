variable "aws_region" {
  description = "AWS region where the Terraform state bucket is created."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "aws_region must be us-east-1."
  }
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name used for Terraform state."
  type        = string

  validation {
    condition = (
      length(var.state_bucket_name) >= 3 &&
      length(var.state_bucket_name) <= 63 &&
      can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.state_bucket_name)) &&
      !can(regex("\\.\\.|\\.-|-\\.", var.state_bucket_name)) &&
      !can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.state_bucket_name)) &&
      !can(regex("^(xn--|sthree-|amzn_s3_demo_)", var.state_bucket_name)) &&
      !can(regex("(-s3alias|--ol-s3|\\.mrap|--x-s3|--table-s3)$", var.state_bucket_name))
    )
    error_message = "state_bucket_name must be a valid globally unique S3 bucket name with 3-63 lowercase letters, numbers, periods, or hyphens."
  }
}

variable "owner" {
  description = "Team responsible for the retained state bucket."
  type        = string

  validation {
    condition     = trimspace(var.owner) != ""
    error_message = "owner must not be empty."
  }
}

variable "expires_on" {
  description = "ISO 8601 calendar date used for Academy resource lifecycle tracking."
  type        = string

  validation {
    condition = (
      can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", var.expires_on)) &&
      can(formatdate("YYYY-MM-DD", "${var.expires_on}T00:00:00Z"))
    )
    error_message = "expires_on must be a nonempty ISO date in YYYY-MM-DD format."
  }
}

variable "tags" {
  description = "Additional non-sensitive tags applied by the AWS provider."
  type        = map(string)
  default     = {}
}
