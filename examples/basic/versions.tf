terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }

  # Keep state in a remote backend you control, with versioning and locking. For example:
  #
  # backend "s3" {
  #   bucket       = "<your-state-bucket>"
  #   key          = "c2sp-witness/terraform.tfstate"
  #   region       = "<region>"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Service = "c2sp-witness"
    }
  }
}
