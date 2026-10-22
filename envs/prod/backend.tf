# Prod's state: same bucket, DIFFERENT key. Prod and dev never share state,
# so a mistake in one can't corrupt the other's.
terraform {
  backend "s3" {
    bucket       = "serverless-webapp-tfstate-716145798645"
    key          = "envs/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}