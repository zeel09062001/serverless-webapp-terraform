variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "app_dir" {
  description = "Path to the app/ folder (Lambda code and website files)"
  type        = string
}

# ---- Settings that differ between environments ----

variable "deletion_protection" {
  description = "Protect the table and user pool from deletion"
  type        = bool
}

variable "allow_password_auth" {
  description = "Allow CLI password login (USER_PASSWORD_AUTH)"
  type        = bool
}

variable "extra_browser_origins" {
  description = "Origins allowed in CORS besides the real website, e.g. localhost"
  type        = list(string)
  default     = []
}

variable "create_sender_identity" {
  description = "Whether this environment creates the SES sender identity"
  type        = bool
}

variable "schedule_timezone" {
  type    = string
  default = "UTC"
}

# ---- Contact addresses ----

variable "alert_email" {
  type = string
}

variable "report_sender_email" {
  type = string
}