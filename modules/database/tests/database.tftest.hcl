# Tests for the database module.
# mock_provider: a FAKE AWS. No credentials needed, nothing is created.

mock_provider "aws" {}

variables {
  project_name = "test"
  environment  = "dev"
}

run "table_has_the_expected_settings" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.expenses.name == "test-dev-expenses"
    error_message = "The table name must follow <project>-<environment>-expenses."
  }

  assert {
    condition     = aws_dynamodb_table.expenses.billing_mode == "PAY_PER_REQUEST"
    error_message = "The table must use on-demand billing."
  }

  assert {
    condition     = aws_dynamodb_table.expenses.point_in_time_recovery[0].enabled
    error_message = "Point-in-time recovery must be on: it's the table's backup."
  }

  assert {
    condition     = contains([for index in aws_dynamodb_table.expenses.global_secondary_index : index.name], "GSI1")
    error_message = "GSI1 must exist: the API and monthly report query it."
  }
}

run "deletion_protection_is_off_by_default" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.expenses.deletion_protection_enabled == false
    error_message = "Deletion protection should only be on when an environment asks for it."
  }
}

run "deletion_protection_can_be_turned_on" {
  command = plan

  variables {
    environment         = "prod"
    deletion_protection = true
  }

  assert {
    condition     = aws_dynamodb_table.expenses.deletion_protection_enabled == true
    error_message = "deletion_protection = true must protect the table."
  }
}