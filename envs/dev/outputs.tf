output "hello_url" {
  description = "Open this in your browser"
  value       = "${trimsuffix(module.api.api_url, "/")}/hello"
}

output "lambda_function_name" {
  value = module.api.lambda_function_name
}

output "time_url" {
  description = "Open this in your browser to see the current time"
  value       = "${trimsuffix(module.api.api_url, "/")}/time"
}
