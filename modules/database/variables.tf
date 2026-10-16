variable "project_name" {
  description = "Prefix for resource names"
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev or prod"
  type        = string
}

variable "deletion_protection" {
  description = "Prevent the table from being deleted. Should be true in prod."
  type        = bool
  default     = false
}