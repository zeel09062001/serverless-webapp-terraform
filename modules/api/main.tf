# =============================================================================
# API MODULE
# One Lambda function behind an API Gateway HTTP API.
# For now it serves GET /hello. Later we'll add the real routes.
# =============================================================================

locals {
  name = "${var.project_name}-${var.environment}"
}

# --- Package the Python code into a zip that Lambda can run ------------------
data "archive_file" "hello" {
  type        = "zip"
  source_dir  = var.lambda_source_dir
  output_path = "${path.root}/build/hello.zip"
}

# --- IAM role the Lambda runs as ---------------------------------------------
# Trust policy: only the Lambda service may use this role
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
  name               = "${local.name}-hello-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

# Least privilege: this managed policy only allows writing logs
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- Log group (created by Terraform so we control retention = cost) ---------
resource "aws_cloudwatch_log_group" "hello" {
  name              = "/aws/lambda/${local.name}-hello"
  retention_in_days = 14
}

# --- The Lambda function ------------------------------------------------------
resource "aws_lambda_function" "hello" {
  function_name    = "${local.name}-hello"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler" # file handler.py, function handler()
  filename         = data.archive_file.hello.output_path
  source_code_hash = data.archive_file.hello.output_base64sha256 # redeploy when code changes
  timeout          = 10
  memory_size      = 128

  depends_on = [
    aws_iam_role_policy_attachment.lambda_logs,
    aws_cloudwatch_log_group.hello,
  ]
}

# --- API Gateway (HTTP API) ---------------------------------------------------
resource "aws_apigatewayv2_api" "this" {
  name          = "${local.name}-api"
  protocol_type = "HTTP"
}

# Connects the API to the Lambda
resource "aws_apigatewayv2_integration" "hello" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.hello.invoke_arn
  payload_format_version = "2.0"
}

# GET /hello -> the integration above
resource "aws_apigatewayv2_route" "hello" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /hello"
  target    = "integrations/${aws_apigatewayv2_integration.hello.id}"
}

resource "aws_apigatewayv2_route" "time" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /time"
  target    = "integrations/${aws_apigatewayv2_integration.hello.id}"
}

# The live "stage" that serves traffic; auto_deploy publishes changes
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
}

# Permission for API Gateway to invoke the Lambda
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
