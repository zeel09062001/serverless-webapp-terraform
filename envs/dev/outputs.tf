output "api_url" {
  value = module.stack.api_url
}

output "website_url" {
  value = module.stack.website_url
}

output "user_pool_id" {
  value = module.stack.user_pool_id
}

output "user_pool_client_id" {
  value = module.stack.user_pool_client_id
}

output "expenses_table_name" {
  value = module.stack.expenses_table_name
}

output "lambda_function_name" {
  value = module.stack.lambda_function_name
}

output "receipts_queue_url" {
  value = module.stack.receipts_queue_url
}

output "receipts_dlq_url" {
  value = module.stack.receipts_dlq_url
}

output "monthly_report_function" {
  value = module.stack.monthly_report_function
}

output "dashboard_url" {
  value = module.stack.dashboard_url
}