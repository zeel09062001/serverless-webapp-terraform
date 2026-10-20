variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "api_id" {
  type = string
}

variable "api_access_log_group_name" {
  type = string
}

variable "lambda_function_names" {
  description = "Short label -> Lambda function name, e.g. { api = \"...-expenses-api\" }"
  type        = map(string)
}

variable "receipts_queue_name" {
  type = string
}

variable "receipts_dlq_name" {
  type = string
}

variable "report_dlq_name" {
  type = string
}

variable "alarm_topic_arn" {
  type = string
}