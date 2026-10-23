# Tests for the receipts module: the bucket must stay private.

mock_provider "aws" {}

variables {
  project_name         = "test"
  environment          = "dev"
  cors_allowed_origins = ["https://example.cloudfront.net"]
}

run "bucket_can_never_be_public" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.receipts.block_public_acls,
      aws_s3_bucket_public_access_block.receipts.block_public_policy,
      aws_s3_bucket_public_access_block.receipts.ignore_public_acls,
      aws_s3_bucket_public_access_block.receipts.restrict_public_buckets,
    ])
    error_message = "All four S3 public access blocks must be on for the receipts bucket."
  }
}

run "deleted_receipts_are_recoverable" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.receipts.versioning_configuration[0].status == "Enabled"
    error_message = "Versioning must be on, so deleted or overwritten receipts can be recovered."
  }
}

run "browsers_may_only_upload_and_download" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_cors_configuration.receipts.cors_rule).allowed_origins == toset(["https://example.cloudfront.net"])
    error_message = "CORS must allow exactly the origins passed in, nothing else."
  }

  assert {
    condition     = !contains(one(aws_s3_bucket_cors_configuration.receipts.cors_rule).allowed_methods, "DELETE")
    error_message = "Browsers must never be allowed to DELETE receipts directly."
  }
}