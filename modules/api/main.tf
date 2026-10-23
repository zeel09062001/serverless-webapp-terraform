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
    "POST /expenses/{id}/receipt",
    "GET /expenses/{id}/receipt",
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

resource "aws_iam_role_policy_attachment" "lambda_xray" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
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
      var.table_arn,
      var.index_arns,
    ]
  }

  # Upload (signing presigned forms), download, and delete receipt files,
  # only inside the receipts/ folder
  statement {
    sid       = "ReceiptObjects"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["${var.receipts_bucket_arn}/receipts/*"]
  }

  # Lets S3 answer "404 not found" instead of "403 forbidden"
  # when we check whether a receipt exists
  statement {
    sid       = "ReceiptExistenceChecks"
    actions   = ["s3:ListBucket"]
    resources = [var.receipts_bucket_arn]
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
  #checkov:skip=CKV_AWS_115:Concurrency is already limited by API Gateway throttling (10 rps, burst 20) before Lambda is invoked.
  function_name    = "${local.name}-expenses-api"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  timeout          = 10
  memory_size      = 256 # measured: same cost as 128 MB, 2x faster, ~100 MB used (see performance report)

  tracing_config {
    mode = "Active"
  }
  # Configuration passed to the code as environment variables
  environment {
    variables = {
      TABLE_NAME      = var.table_name
      RECEIPTS_BUCKET = var.receipts_bucket_name
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

# One JSON line per API request, written by API Gateway itself
resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name}-api"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn

    format = join("", [
      "{",
      join(",", [
        "\"requestId\":\"$context.requestId\"",
        "\"time\":\"$context.requestTime\"",
        "\"ip\":\"$context.identity.sourceIp\"",
        "\"routeKey\":\"$context.routeKey\"",
        "\"status\":$context.status",
        "\"latencyMs\":$context.responseLatency",
        "\"integrationLatencyMs\":\"$context.integrationLatency\"",
        "\"responseBytes\":\"$context.responseLength\"",
        "\"userId\":\"$context.authorizer.claims.sub\"",
        "\"integrationError\":\"$context.integrationErrorMessage\"",
        "\"authorizerError\":\"$context.authorizer.error\"",
      ]),
      "}",
    ])
  }
}
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
