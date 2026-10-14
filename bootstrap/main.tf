# =============================================================================
# BOOTSTRAP
# Run ONCE from your laptop. Creates the foundation everything else depends on:
#   1. An S3 bucket to store Terraform's state (its "notebook")
#   2. A GitHub OIDC provider (lets AWS trust GitHub's identity tokens)
#   3. An IAM role that GitHub Actions can assume to deploy your project
#
# This folder keeps its own state LOCALLY (terraform.tfstate in this folder).
# That's normal for bootstrap. The file is gitignored; keep a backup copy.
# =============================================================================

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # These tags are added to EVERY resource automatically
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Component = "bootstrap"
    }
  }
}

# Looks up your AWS account ID so we can make the bucket name globally unique
data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# -----------------------------------------------------------------------------
# 1. TERRAFORM STATE BUCKET
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "tf_state" {
  bucket = local.state_bucket_name

  # Safety net: Terraform will refuse to delete this bucket by accident
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning keeps every old version of the state file -> you can recover
resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# State can contain sensitive values, so encrypt it at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# The state bucket must never be public
resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# 2. GITHUB OIDC PROVIDER
# Tells AWS: "identity tokens issued by GitHub Actions can be trusted"
# -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

# -----------------------------------------------------------------------------
# 3. IAM ROLE FOR GITHUB ACTIONS
# The trust policy says WHO may use this role: only workflows running in
# YOUR repository. Nobody else on GitHub can assume it.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Locks the role to your repo only
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project_name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

# NOTE: AdministratorAccess is a deliberate simplification for a learning
# project, because Terraform needs to create many kinds of resources
# (including IAM roles for Lambda). The trust policy above limits WHO can use
# it. Record this in your security documentation as a known item to tighten
# to least privilege later.
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
