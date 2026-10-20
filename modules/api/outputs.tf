output "api_url" {
  description = "Base URL of the API"
  value       = aws_apigatewayv2_stage.default.invoke_url
}
output "lambda_function_name" {
  value = aws_lambda_function.api.function_name
}
output "api_id" {
  value = aws_apigatewayv2_api.this.id
}
output "access_log_group_name" {
  value = aws_cloudwatch_log_group.api_access.name
}