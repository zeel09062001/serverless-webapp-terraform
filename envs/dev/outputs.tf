output "api_url" {
  description = "Base URL of the expenses API"
  value       = trimsuffix(module.api.api_url, "/")
}

output "lambda_function_name" {
  value = module.api.lambda_function_name
}

output "expenses_table_name" {
  value = module.database.table_name
}