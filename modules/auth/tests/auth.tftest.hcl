# Tests for the auth module: login security rules.

mock_provider "aws" {}

variables {
  project_name = "test"
  environment  = "dev"
}

run "web_client_is_a_safe_public_client" {
  command = plan

  assert {
    condition     = aws_cognito_user_pool_client.web.generate_secret == false
    error_message = "Browser apps can't keep a secret, so the web client must not have one."
  }

  assert {
    condition     = aws_cognito_user_pool_client.web.prevent_user_existence_errors == "ENABLED"
    error_message = "Login errors must not reveal whether an email is registered (user enumeration)."
  }

  assert {
    condition     = contains(aws_cognito_user_pool_client.web.explicit_auth_flows, "ALLOW_USER_SRP_AUTH")
    error_message = "SRP login must be allowed: the website uses it."
  }
}

run "password_login_is_off_by_default" {
  command = plan

  assert {
    condition     = !contains(aws_cognito_user_pool_client.web.explicit_auth_flows, "ALLOW_USER_PASSWORD_AUTH")
    error_message = "USER_PASSWORD_AUTH must be off unless an environment explicitly enables it."
  }
}

run "password_login_only_when_explicitly_enabled" {
  command = plan

  variables {
    allow_password_auth = true
  }

  assert {
    condition     = contains(aws_cognito_user_pool_client.web.explicit_auth_flows, "ALLOW_USER_PASSWORD_AUTH")
    error_message = "allow_password_auth = true must enable USER_PASSWORD_AUTH."
  }
}

run "deletion_protection_means_active" {
  command = plan

  variables {
    deletion_protection = true
  }

  assert {
    condition     = aws_cognito_user_pool.this.deletion_protection == "ACTIVE"
    error_message = "deletion_protection = true must protect the user pool."
  }
}