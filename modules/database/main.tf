# =============================================================================
# DATABASE MODULE
# One DynamoDB table using single-table design.
#
# Main table:  PK = USER#<userId>      SK = EXPENSE#<expenseId>
#   -> get / update / delete one expense (AP1-AP4)
# GSI1:        GSI1PK = USER#<userId>  GSI1SK = DATE#<YYYY-MM-DD>#<expenseId>
#   -> list a user's expenses for a month, newest first (AP5)
# =============================================================================

resource "aws_dynamodb_table" "expenses" {
  name         = "${var.project_name}-${var.environment}-expenses"
  billing_mode = "PAY_PER_REQUEST" # on-demand: pay per request, no capacity planning
  hash_key     = "PK"              # partition key (the "drawer")
  range_key    = "SK"              # sort key (folder order inside the drawer)

  # Only KEY attributes are declared. All other fields are schemaless.
  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  attribute {
    name = "GSI1PK"
    type = "S"
  }

  attribute {
    name = "GSI1SK"
    type = "S"
  }

  # The second "filing cabinet": same items, sorted by date
  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL" # copy all attributes into the index
  }

  # Continuous backups: restore to any second in the last 35 days
  point_in_time_recovery {
    enabled = true
  }

  # Blocks table deletion (even by Terraform) when true. On for prod.
  deletion_protection_enabled = var.deletion_protection
}