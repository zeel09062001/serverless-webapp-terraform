variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "serverless-webapp"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "alert_email" {
  type = string
}

variable "report_sender_email" {
  type = string
}