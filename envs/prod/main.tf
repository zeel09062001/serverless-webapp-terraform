terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
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

# The whole application, with PRODUCTION settings
module "stack" {
  source       = "../../modules/stack"
  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  app_dir      = "${path.root}/../../app"

  deletion_protection    = true  # the table and user pool can't be deleted by accident
  allow_password_auth    = false # only the website's SRP login
  extra_browser_origins  = []    # only the real website may call the API
  create_sender_identity = false # dev already created it (same AWS account)
  schedule_timezone      = "UTC"

  alert_email         = var.alert_email
  report_sender_email = var.report_sender_email
}