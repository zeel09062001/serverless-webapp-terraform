variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "lambda_source_dir" {
  type = string
}

variable "table_name" {
  type = string
}

variable "table_arn" {
  type = string
}

variable "index_arns" {
  type = string
}

variable "user_pool_id" {
  type = string
}

variable "user_pool_arn" {
  type = string
}

variable "sender_email" {
  description = "Verified SES address that reports are sent from"
  type        = string
}

variable "schedule_expression" {
  description = "When to run. Default: 08:00 on the 1st of every month."
  type        = string
  default     = "cron(0 8 1 * ? *)"
}

variable "schedule_timezone" {
  description = "Time zone for the schedule, e.g. UTC or Asia/Kolkata"
  type        = string
  default     = "UTC"
}

variable "alarm_topic_arn" {
  type = string
}