# =============================================================================
# MONTHLY REPORT MODULE
# EventBridge Scheduler -> report Lambda -> SES email to each user.
# Failed runs are retried; runs that keep failing go to a DLQ with an alarm.
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  name = "${var.project_name}-${var.environment}"
}

# -----------------------------------------------------------------------------
# SES: the address emails are sent FROM. AWS emails it a verification link.
# -----------------------------------------------------------------------------
resource "aws_sesv2_email_identity" "sender" {
  email_identity = var.sender_email
}

# -----------------------------------------------------------------------------
# Dead-letter queue for runs that fail every retry
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name}-monthly-report-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

# -----------------------------------------------------------------------------
# Report Lambda
# -----------------------------------------------------------------------------
data "archive_file" "report" {
  type        = "zip"
  source_dir  = var.lambda_source_dir
  output_path = "${path.root}/build/monthly_report.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "report" {
  name               = "${local.name}-monthly-report"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "report_logs" {
  role       = aws_iam_role.report.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "report_xray" {
  role       = aws_iam_role.report.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "report" {
  # Read each user's expenses for the month (the GSI query)
  statement {
    sid       = "ReadExpenses"
    actions   = ["dynamodb:Query"]
    resources = [var.table_arn, var.index_arns]
  }

  # Write, update and remove the REPORT#<month> markers
  statement {
    sid       = "ReportMarkers"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
    resources = [var.table_arn]
  }

  # List users and their emails
  statement {
    sid       = "ListUsers"
    actions   = ["cognito-idp:ListUsers"]
    resources = [var.user_pool_arn]
  }

  # Send email, but ONLY from our verified sender address
  statement {
    sid       = "SendReports"
    actions   = ["ses:SendEmail"]
    resources = [aws_sesv2_email_identity.sender.arn]

    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.sender_email]
    }
  }

  # Lambda's own retry mechanism sends failed runs to the DLQ
  statement {
    sid       = "SendFailuresToDlq"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
  }
}

resource "aws_iam_role_policy" "report" {
  name   = "monthly-report-access"
  role   = aws_iam_role.report.id
  policy = data.aws_iam_policy_document.report.json
}

resource "aws_cloudwatch_log_group" "report" {
  name              = "/aws/lambda/${local.name}-monthly-report"
  retention_in_days = 14
}

resource "aws_lambda_function" "report" {
  function_name    = "${local.name}-monthly-report"
  role             = aws_iam_role.report.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.report.output_path
  source_code_hash = data.archive_file.report.output_base64sha256

  # Loops over every user, so it needs longer than an API call.
  # Lambda's hard maximum is 15 minutes (see the fan-out discussion).
  timeout     = 300
  memory_size = 256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      TABLE_NAME   = var.table_name
      USER_POOL_ID = var.user_pool_id
      SENDER_EMAIL = var.sender_email
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.report_logs,
    aws_iam_role_policy.report,
    aws_cloudwatch_log_group.report,
  ]
}

# When the function itself fails (raises an error), Lambda retries it twice,
# then sends the event to the DLQ.
resource "aws_lambda_function_event_invoke_config" "report" {
  function_name                = aws_lambda_function.report.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600

  destination_config {
    on_failure {
      destination = aws_sqs_queue.dlq.arn
    }
  }
}

# -----------------------------------------------------------------------------
# EventBridge Scheduler: runs the Lambda on the 1st of every month
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name}-monthly-report-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.report.arn]
  }
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "invoke-monthly-report"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "monthly" {
  name = "${local.name}-monthly-report"

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  # Run at exactly the scheduled time (FLEXIBLE would spread runs out)
  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.report.arn
    role_arn = aws_iam_role.scheduler.arn

    # Scheduler replaces this placeholder with the run's scheduled time (UTC)
    input = jsonencode({
      scheduledTime = "<aws.scheduler.scheduled-time>"
    })

    # If Scheduler can't even start the Lambda (e.g. throttling), retry,
    # then send the event to the DLQ
    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }

    dead_letter_config {
      arn = aws_sqs_queue.dlq.arn
    }
  }
}

# -----------------------------------------------------------------------------
# Alarm: a report run failed every attempt
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name        = "${local.name}-monthly-report-dlq-not-empty"
  alarm_description = "A monthly report run failed all retries. Check the Lambda logs, fix the cause, then re-run it by hand for the failed month."

  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }

  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.alarm_topic_arn]
  ok_actions    = [var.alarm_topic_arn]
}