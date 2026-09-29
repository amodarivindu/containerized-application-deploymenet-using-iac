terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }

  # State is stored in S3 (bucket created by terraform/bootstrap).
  # bucket and region are passed at init time:
  #   terraform init -backend-config="bucket=<name>" -backend-config="region=us-east-1"
  backend "s3" {
    key          = "ecs-app/terraform.tfstate"
    use_lockfile = true # prevents two applies running at the same time
  }
}

provider "aws" {
  region = var.aws_region

  # Added to every resource, so you can find them in the console and on the bill.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
    }
  }
}

# Common name prefix, e.g. "ecs-demo-dev"
locals {
  name = "${var.project_name}-${var.environment}"
}
