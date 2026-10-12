output "hello_url" {
  description = "Open this in your browser"
  value       = "${trimsuffix(module.api.api_url, "/")}/hello"
}

output "lambda_function_name" {
  value = module.api.lambda_function_name
}
