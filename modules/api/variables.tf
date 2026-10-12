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
