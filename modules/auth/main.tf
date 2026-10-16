# =============================================================================
# AUTH MODULE
# A Cognito user pool (the user directory) and an app client (how our
# web app and CLI tests are allowed to log in).
# =============================================================================

locals {
  name = "${var.project_name}-${var.environment}"
}

# --- User pool: stores user accounts ---------------------------------------------
resource "aws_cognito_user_pool" "this" {
  name = "${local.name}-users"

  # Users sign in with their email address instead of a separate username
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"] # Cognito emails a verification code

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  deletion_protection = var.deletion_protection ? "ACTIVE" : "INACTIVE"
}

# --- App client: how an application is allowed to log users in -----------------
resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.name}-web"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = false

  explicit_auth_flows = concat(
    ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"],
    var.allow_password_auth ? ["ALLOW_USER_PASSWORD_AUTH"] : []
  )

  # Login errors don't reveal whether an email is registered
  prevent_user_existence_errors = "ENABLED"

  # Short-lived access/ID tokens, longer-lived refresh token
  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  enable_token_revocation = true
}