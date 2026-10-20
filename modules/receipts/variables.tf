variable "project_name" {
  description = "Prefix for resource names"
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev or prod"
  type        = string
}

variable "cors_allowed_origins" {
  description = "Website origins allowed to upload and download from a browser"
  type        = list(string)
}