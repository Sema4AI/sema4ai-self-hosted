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

  # State backend intentionally not configured — add your organization's
  # standard backend (e.g. S3) here. With no backend, state is stored locally
  # in terraform.tfstate, which contains the Aurora master password when the
  # optional database is enabled: protect it accordingly.
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
