output "api_url" {
  value = trimsuffix(module.api.api_url, "/")
}

output "website_url" {
  value = module.frontend.website_url
}

output "user_pool_id" {
  value = module.auth.user_pool_id
}

output "user_pool_client_id" {
  value = module.auth.client_id
}

output "expenses_table_name" {
  value = module.database.table_name
}

output "lambda_function_name" {
  value = module.api.lambda_function_name
}

output "receipts_queue_url" {
  value = module.receipt_processing.queue_url
}

output "receipts_dlq_url" {
  value = module.receipt_processing.dlq_url
}

output "monthly_report_function" {
  value = module.monthly_report.function_name
}

output "dashboard_url" {
  value = module.observability.dashboard_url
}