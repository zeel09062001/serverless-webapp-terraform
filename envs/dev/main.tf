terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Call the API module. Later: database, frontend, auth, monitoring modules go here too.
module "api" {
  source            = "../../modules/api"
  project_name      = var.project_name
  environment       = var.environment
  lambda_source_dir = "${path.root}/../../app/lambdas/hello"
}
