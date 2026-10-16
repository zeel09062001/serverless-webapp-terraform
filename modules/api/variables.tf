variable "project_name" {
  description = "Prefix for resource names"
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev or prod"
  type        = string
}

variable "lambda_source_dir" {
  description = "Path to the folder containing the Lambda code"
  type        = string
}

variable "table_name" {
  description = "Name of the DynamoDB expenses table"
  type        = string
}

variable "table_arn" {
  description = "ARN of the DynamoDB expenses table"
  type        = string
}

variable "index_arns" {
  description = "ARN pattern covering the table's indexes"
  type        = string
}

variable "cognito_issuer_url" {
  description = "Issuer URL of the Cognito user pool"
  type        = string
}

variable "cognito_client_id" {
  description = "Cognito app client ID allowed to call this API"
  type        = string
}