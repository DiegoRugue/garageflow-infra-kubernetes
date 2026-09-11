terraform {
  required_version = "= 1.15.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.49.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}
