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

# User accounts and login
module "auth" {
  source              = "../../modules/auth"
  project_name        = var.project_name
  environment         = var.environment
  deletion_protection = false # dev can be torn down freely
  allow_password_auth = true  # lets us test login from the CLI in dev
}

# Website hosting: private S3 bucket + CloudFront
module "frontend" {
  source       = "../../modules/frontend"
  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  site_dir     = "${path.root}/../../app/frontend"
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

  cognito_issuer_url = module.auth.issuer_url
  cognito_client_id  = module.auth.client_id
  cors_allowed_origins = [
    module.frontend.website_url,
    "http://localhost:8080",
  ]
}

# Website configuration, generated from other modules' outputs.
# Lives here (not in the frontend module) to avoid a dependency cycle:
# the API needs the website URL for CORS, and this file needs the API URL.
resource "aws_s3_object" "frontend_config" {
  bucket        = module.frontend.bucket_name
  key           = "config.js"
  content_type  = "application/javascript; charset=utf-8"
  cache_control = "no-cache"

  content = <<-EOT
    window.APP_CONFIG = ${jsonencode({
  apiUrl           = trimsuffix(module.api.api_url, "/")
  region           = var.aws_region
  userPoolId       = module.auth.user_pool_id
  userPoolClientId = module.auth.client_id
})};
  EOT
}