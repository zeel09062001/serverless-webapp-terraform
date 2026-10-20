# =============================================================================
# RECEIPTS MODULE
# Private bucket for receipt files. Browsers upload and download
# directly, using short-lived presigned URLs created by the API Lambda.
# Object layout: receipts/<userId>/<expenseId>
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  name = "${var.project_name}-${var.environment}"
}

resource "aws_s3_bucket" "receipts" {
  bucket = "${local.name}-receipts-${data.aws_caller_identity.current.account_id}"
}

# Never public, no matter what policy someone writes later
resource "aws_s3_bucket_public_access_block" "receipts" {
  bucket                  = aws_s3_bucket.receipts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning: overwritten or deleted receipts can be recovered
resource "aws_s3_bucket_versioning" "receipts" {
  bucket = aws_s3_bucket.receipts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "receipts" {
  bucket = aws_s3_bucket.receipts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Keep storage costs under control
resource "aws_s3_bucket_lifecycle_configuration" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  rule {
    id     = "cleanup"
    status = "Enabled"
    filter {} # applies to every object

    # Old versions (overwritten or deleted receipts) are kept 30 days, then removed
    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    # Clean up uploads that started but never finished
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.receipts]
}

# Browsers upload (POST) and download (GET) directly, so S3 itself
# must allow our website's origin. Same idea as CORS on the API.
resource "aws_s3_bucket_cors_configuration" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  cors_rule {
    allowed_methods = ["POST", "GET"]
    allowed_origins = var.cors_allowed_origins
    allowed_headers = ["*"]
    max_age_seconds = 3600
  }
}

# Refuse any request that doesn't use HTTPS
data "aws_iam_policy_document" "receipts" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.receipts.arn, "${aws_s3_bucket.receipts.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "receipts" {
  bucket     = aws_s3_bucket.receipts.id
  policy     = data.aws_iam_policy_document.receipts.json
  depends_on = [aws_s3_bucket_public_access_block.receipts]
}