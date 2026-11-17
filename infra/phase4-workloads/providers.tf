terraform {
  required_version = "= 1.15.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.49.0"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project     = "GarageFlow"
      Environment = var.environment
      Component   = "phase4-workloads"
    }
  }
}
