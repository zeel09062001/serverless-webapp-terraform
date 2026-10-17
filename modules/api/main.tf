# =============================================================================
# API MODULE
# One Lambda function (the expenses API) behind an API Gateway HTTP API.
# =============================================================================

locals {
  name = "${var.project_name}-${var.environment}"

  # Every route the API exposes. All of them go to the same Lambda,
  # which picks the right handler using the route key.
  routes = toset([
    "POST /expenses",
    "GET /expenses",
    "GET /expenses/{id}",
    "PUT /expenses/{id}",
    "DELETE /expenses/{id}",
  ])
}

# --- Package the Python code --------------------------------------------------
data "archive_file" "api" {
  type        = "zip"
  source_dir  = var.lambda_source_dir
  output_path = "${path.root}/build/expenses_api.zip"
}

# --- IAM role: WHO the Lambda is ----------------------------------------------
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-api-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

# Permission to write logs
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- IAM permissions: WHAT the Lambda may do in DynamoDB ----------------------
# Least privilege: only the 5 operations our code uses, only on our table
# and its indexes. Notably NOT Scan, because our design never needs it.
data "aws_iam_policy_document" "dynamodb_access" {
  statement {
    sid = "ExpensesTableAccess"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
    ]
    resources = [
      var.table_arn,  # the table itself
      var.index_arns, # its indexes (needed to Query GSI1)
    ]
  }
}

resource "aws_iam_role_policy" "dynamodb_access" {
  name   = "dynamodb-expenses-access"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.dynamodb_access.json
}

# --- Log group ---------------------------------------------------------------
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${local.name}-expenses-api"
  retention_in_days = 14
}

# --- The Lambda function -------------------------------------------------------
resource "aws_lambda_function" "api" {
  function_name    = "${local.name}-expenses-api"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  architectures    = ["arm64"] # Graviton: about 20% cheaper than x86
  handler          = "handler.handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  timeout          = 10
  memory_size      = 256 # more memory also means more CPU = faster cold starts

  # Configuration passed to the code as environment variables
  environment {
    variables = {
      TABLE_NAME = var.table_name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_logs,
    aws_iam_role_policy.dynamodb_access,
    aws_cloudwatch_log_group.api,
  ]
}

# --- API Gateway -----------------------------------------------------------------
resource "aws_apigatewayv2_api" "this" {
  name          = "${local.name}-api"
  protocol_type = "HTTP"

  # Which websites may call this API from a browser.
  # API Gateway answers the browser's preflight (OPTIONS) requests itself.
  cors_configuration {
    allow_origins = var.cors_allowed_origins
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 3600 # browsers may remember the answer for 1 hour
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

# Verifies the login token on every request BEFORE the Lambda runs.
# It checks the signature (using Cognito's public keys), the issuer,
# the expiry time, and that the token was issued for our app client.
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.this.id
  name             = "cognito-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = var.cognito_issuer_url
    audience = [var.cognito_client_id]
  }
}

# One route resource per entry in local.routes
resource "aws_apigatewayv2_route" "this" {
  for_each = local.routes

  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"

  # Every route requires a valid Cognito token
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  # Rate limiting: protects against floods and surprise bills
  default_route_settings {
    throttling_burst_limit = 20 # max requests at the same instant
    throttling_rate_limit  = 10 # steady requests per second
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}