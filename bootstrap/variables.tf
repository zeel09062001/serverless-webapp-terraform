variable "aws_region" {
  description = "AWS region for the state bucket and the whole project"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short lowercase name, used as a prefix for resource names"
  type        = string
  default     = "serverless-webapp"
}

variable "github_owner" {
  description = "Your GitHub username (or organization name)"
  type        = string
}

variable "github_repo" {
  description = "Name of your GitHub repository"
  type        = string
  default     = "serverless-webapp-terraform"
}

variable "github_owner_id" {
  description = "Numeric ID of your GitHub account (never changes)"
  type        = string
}

variable "github_repo_id" {
  description = "Numeric ID of your GitHub repository (never changes)"
  type        = string
}
