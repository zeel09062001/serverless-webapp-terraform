variable "project_name" {
  description = "Prefix for resource names"
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev or prod"
  type        = string
}

variable "aws_region" {
  description = "Region of the API and Cognito (used in the Content Security Policy)"
  type        = string
}

variable "site_dir" {
  description = "Folder containing the website files"
  type        = string
}