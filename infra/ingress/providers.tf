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
  region = "us-east-1"
}
