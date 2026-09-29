terraform {
  # 1.10+ is required for S3-native state locking (use_lockfile).
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }

  # Partial backend config - bucket and region are supplied at init time:
  #   terraform init -backend-config=backend.hcl
  # (Jenkins passes them as -backend-config flags.)
  backend "s3" {
    key          = "ecs-app/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
