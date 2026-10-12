# These values are printed after apply. You'll copy them into GitHub
# and into the backend config of envs/dev and envs/prod.

output "state_bucket_name" {
  value = aws_s3_bucket.tf_state.bucket
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

output "aws_region" {
  value = var.aws_region
}
