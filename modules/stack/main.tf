# =============================================================================
# STACK MODULE
# The whole application: every module, wired together.
# Each environment (dev, prod) calls this ONCE with its own settings,
# so all environments are guaranteed to have the same architecture.
# =============================================================================

locals {
  # Websites allowed to call our API and buckets from a browser
  browser_origins = concat([module.frontend.website_url], var.extra_browser_origins)
}

module "database" {
  source              = "../database"
  project_name        = var.project_name
  environment         = var.environment
  deletion_protection = var.deletion_protection
}

module "auth" {
  source              = "../auth"
  project_name        = var.project_name
  environment         = var.environment
  deletion_protection = var.deletion_protection
  allow_password_auth = var.allow_password_auth
}

module "frontend" {
  source       = "../frontend"
  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  site_dir     = "${var.app_dir}/frontend"
}

module "receipts" {
  source               = "../receipts"
  project_name         = var.project_name
  environment          = var.environment
  cors_allowed_origins = local.browser_origins
}

module "api" {
  source            = "../api"
  project_name      = var.project_name
  environment       = var.environment
  lambda_source_dir = "${var.app_dir}/lambdas/expenses_api"

  table_name = module.database.table_name
  table_arn  = module.database.table_arn
  index_arns = module.database.index_arns

  cognito_issuer_url = module.auth.issuer_url
  cognito_client_id  = module.auth.client_id

  cors_allowed_origins = local.browser_origins

  receipts_bucket_name = module.receipts.bucket_name
  receipts_bucket_arn  = module.receipts.bucket_arn
}

module "monitoring" {
  source       = "../monitoring"
  project_name = var.project_name
  environment  = var.environment
  alert_email  = var.alert_email
}

module "receipt_processing" {
  source            = "../receipt_processing"
  project_name      = var.project_name
  environment       = var.environment
  lambda_source_dir = "${var.app_dir}/lambdas/receipt_worker"

  receipts_bucket_name = module.receipts.bucket_name
  receipts_bucket_arn  = module.receipts.bucket_arn
  table_name           = module.database.table_name
  table_arn            = module.database.table_arn
  alarm_topic_arn      = module.monitoring.alerts_topic_arn
}

module "monthly_report" {
  source            = "../monthly_report"
  project_name      = var.project_name
  environment       = var.environment
  aws_region        = var.aws_region
  lambda_source_dir = "${var.app_dir}/lambdas/monthly_report"

  table_name    = module.database.table_name
  table_arn     = module.database.table_arn
  index_arns    = module.database.index_arns
  user_pool_id  = module.auth.user_pool_id
  user_pool_arn = module.auth.user_pool_arn

  sender_email           = var.report_sender_email
  create_sender_identity = var.create_sender_identity
  schedule_timezone      = var.schedule_timezone
  alarm_topic_arn        = module.monitoring.alerts_topic_arn
}

module "observability" {
  source       = "../observability"
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

# Website configuration, generated from other modules' outputs
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