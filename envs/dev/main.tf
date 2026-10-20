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

locals {
  # Websites allowed to call our API and buckets from a browser
  browser_origins = [
    module.frontend.website_url,
    "http://localhost:8080", # local development
  ]
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

module "receipts" {
  source               = "../../modules/receipts"
  project_name         = var.project_name
  environment          = var.environment
  cors_allowed_origins = local.browser_origins
}

# Alert emails
module "monitoring" {
  source       = "../../modules/monitoring"
  project_name = var.project_name
  environment  = var.environment
  alert_email  = var.alert_email
}

# Background processing: S3 -> SQS -> worker Lambda, with DLQ and alarm
module "receipt_processing" {
  source            = "../../modules/receipt_processing"
  project_name      = var.project_name
  environment       = var.environment
  lambda_source_dir = "${path.root}/../../app/lambdas/receipt_worker"

  receipts_bucket_name = module.receipts.bucket_name
  receipts_bucket_arn  = module.receipts.bucket_arn
  table_name           = module.database.table_name
  table_arn            = module.database.table_arn
  alarm_topic_arn      = module.monitoring.alerts_topic_arn
}

# Monthly summary emails: Scheduler -> Lambda -> SES
module "monthly_report" {
  source            = "../../modules/monthly_report"
  project_name      = var.project_name
  environment       = var.environment
  lambda_source_dir = "${path.root}/../../app/lambdas/monthly_report"

  table_name    = module.database.table_name
  table_arn     = module.database.table_arn
  index_arns    = module.database.index_arns
  user_pool_id  = module.auth.user_pool_id
  user_pool_arn = module.auth.user_pool_arn

  sender_email      = var.report_sender_email
  schedule_timezone = "UTC" # change to your own, e.g. "Asia/Kolkata"
  alarm_topic_arn   = module.monitoring.alerts_topic_arn
}

# Dashboard, alarms and saved log queries for the whole system.
# Depends on every other module, so it must come last in the dependency chain.
module "observability" {
  source       = "../../modules/observability"
  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region

  api_id                    = module.api.api_id
  api_access_log_group_name = module.api.access_log_group_name

  lambda_function_names = {
    api            = module.api.lambda_function_name
    receipt_worker = module.receipt_processing.worker_function_name
    monthly_report = module.monthly_report.function_name
  }

  receipts_queue_name = module.receipt_processing.queue_name
  receipts_dlq_name   = module.receipt_processing.dlq_name
  report_dlq_name     = module.monthly_report.dlq_name

  alarm_topic_arn = module.monitoring.alerts_topic_arn
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

  cognito_issuer_url   = module.auth.issuer_url
  cognito_client_id    = module.auth.client_id
  cors_allowed_origins = local.browser_origins

  receipts_bucket_name = module.receipts.bucket_name
  receipts_bucket_arn  = module.receipts.bucket_arn
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