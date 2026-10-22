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

# The whole application, with dev's settings
module "stack" {
  source       = "../../modules/stack"
  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  app_dir      = "${path.root}/../../app"

  deletion_protection    = false                     # dev can be torn down freely
  allow_password_auth    = true                      # lets us test login from the CLI
  extra_browser_origins  = ["http://localhost:8080"] # local development server
  create_sender_identity = true                      # dev owns the SES identity
  schedule_timezone      = "UTC"

  alert_email         = var.alert_email
  report_sender_email = var.report_sender_email
}

# -----------------------------------------------------------------------------
# Refactoring: everything moved inside module.stack.
# These blocks tell Terraform the resources MOVED (update the state only)
# instead of being deleted and recreated. They can be removed later, once
# every environment's state has been updated.
# -----------------------------------------------------------------------------
moved {
  from = module.database
  to   = module.stack.module.database
}

moved {
  from = module.auth
  to   = module.stack.module.auth
}

moved {
  from = module.frontend
  to   = module.stack.module.frontend
}

moved {
  from = module.receipts
  to   = module.stack.module.receipts
}

moved {
  from = module.api
  to   = module.stack.module.api
}

moved {
  from = module.monitoring
  to   = module.stack.module.monitoring
}

moved {
  from = module.receipt_processing
  to   = module.stack.module.receipt_processing
}

moved {
  from = module.monthly_report
  to   = module.stack.module.monthly_report
}

moved {
  from = module.observability
  to   = module.stack.module.observability
}

moved {
  from = aws_s3_object.frontend_config
  to   = module.stack.aws_s3_object.frontend_config
}