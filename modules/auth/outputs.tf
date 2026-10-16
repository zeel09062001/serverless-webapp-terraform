output "user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  value = aws_cognito_user_pool.this.arn
}

output "client_id" {
  description = "App client ID: the web app and the API authorizer need this"
  value       = aws_cognito_user_pool_client.web.id
}

output "issuer_url" {
  description = "Who issues the tokens. API Gateway uses this to find the signing keys."
  value       = "https://${aws_cognito_user_pool.this.endpoint}"
}