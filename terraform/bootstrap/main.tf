# Run ONCE to create the S3 bucket that stores Terraform state for the main stack:
#   cd terraform/bootstrap
#   terraform init
#   terraform apply -var="bucket_name=<globally-unique-name>"
# (New S3 buckets are encrypted and block public access by default.)

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "bucket_name" {
  type = string
}

resource "aws_s3_bucket" "tfstate" {
  bucket = var.bucket_name
}

# Keep old versions of the state file so a bad apply can be recovered.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}
