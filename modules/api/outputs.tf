output "api_url" {
  description = "Base URL of the API"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "lambda_function_name" {
  value = aws_lambda_function.hello.function_name
}
