terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }

  # State contains the Aurora master password when the optional database is
  # enabled, hence encrypt = true. The key is per environment, supplied at
  # init time:
  #   terraform init -reconfigure -backend-config=live_vars/<env>.backend.hcl
  #   terraform plan|apply -var-file=live_vars/<env>.tfvars
  backend "s3" {
    bucket  = "mm-iac-terraform-aws"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      service   = var.infra_id
      managedby = "terraform"
    }
  }
}
