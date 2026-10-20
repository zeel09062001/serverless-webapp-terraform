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
  default = "dev"
}
variable "alert_email" {
  description = "Email address for alarm notifications"
  type        = string
}
variable "report_sender_email" {
  description = "SES-verified address that monthly reports are sent from"
  type        = string
}