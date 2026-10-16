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

# Expenses table (single-table design)
module "database" {
  source              = "../../modules/database"
  project_name        = var.project_name
  environment         = var.environment
  deletion_protection = false # dev can be torn down freely
}

# Expenses API: Lambda + API Gateway
module "api" {
  source            = "../../modules/api"
  project_name      = var.project_name
  environment       = var.environment
  lambda_source_dir = "${path.root}/../../app/lambdas/expenses_api"

  # Wiring: outputs of the database module become inputs of the API module
  table_name = module.database.table_name
  table_arn  = module.database.table_arn
  index_arns = module.database.index_arns

  allow_debug_user = true # TEMPORARY: remove once Cognito is added
}