variable "project_name" {
  description = "Prefix for resource names"
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev or prod"
  type        = string
}

variable "deletion_protection" {
  description = "Prevent the user pool from being deleted. Should be true in prod."
  type        = bool
  default     = false
}

variable "allow_password_auth" {
  description = "Allow USER_PASSWORD_AUTH login (for CLI testing). Dev only."
  type        = bool
  default     = false
}