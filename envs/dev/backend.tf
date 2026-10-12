# Where Terraform keeps the dev environment's state: in the bucket bootstrap created.
# use_lockfile = true turns on S3 native locking (no DynamoDB table needed).
terraform {
  backend "s3" {
    bucket       = "serverless-webapp-tfstate-716145798645"
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
