variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "lambda_source_dir" {
  description = "Folder containing the worker's code"
  type        = string
}

variable "receipts_bucket_name" {
  type = string
}

variable "receipts_bucket_arn" {
  type = string
}

variable "table_name" {
  type = string
}

variable "table_arn" {
  type = string
}

variable "alarm_topic_arn" {
  description = "SNS topic that alarms notify"
  type        = string
}