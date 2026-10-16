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

variable "allow_debug_user" {
  description = "Accept the X-Debug-User header. Dev only, before Cognito exists."
  type        = bool
  default     = false
}