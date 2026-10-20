# =============================================================================
# RECEIPT PROCESSING MODULE
# S3 upload -> event notification -> SQS queue -> worker Lambda
# Messages that fail 3 times go to a dead-letter queue (DLQ), which
# triggers an alarm.
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  name = "${var.project_name}-${var.environment}"
}

# -----------------------------------------------------------------------------
# Queues
# -----------------------------------------------------------------------------

# Dead-letter queue: where messages go after failing too many times
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name}-receipts-dlq"
  message_retention_seconds = 1209600 # 14 days: the maximum, time to investigate
  sqs_managed_sse_enabled   = true    # encrypted at rest
}

resource "aws_sqs_queue" "receipts" {
  name = "${local.name}-receipts"

  # Must be longer than the worker's run time (AWS recommends 6x the
  # Lambda timeout), or messages reappear while still being processed.
  visibility_timeout_seconds = 60

  message_retention_seconds = 345600 # 4 days
  sqs_managed_sse_enabled   = true

  # After 3 failed receives, move the message to the DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

# Only OUR bucket, in OUR account, may send messages to this queue
data "aws_iam_policy_document" "queue" {
  statement {
    sid       = "AllowReceiptsBucketNotifications"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.receipts.arn]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.receipts_bucket_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "receipts" {
  queue_url = aws_sqs_queue.receipts.id
  policy    = data.aws_iam_policy_document.queue.json
}

# Tell S3: whenever an object is created under receipts/, notify the queue
resource "aws_s3_bucket_notification" "receipts" {
  bucket = var.receipts_bucket_name

  queue {
    queue_arn     = aws_sqs_queue.receipts.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "receipts/"
  }

  # S3 checks it can send to the queue when this is created
  depends_on = [aws_sqs_queue_policy.receipts]
}

# -----------------------------------------------------------------------------
# Worker Lambda
# -----------------------------------------------------------------------------

data "archive_file" "worker" {
  type        = "zip"
  source_dir  = var.lambda_source_dir
  output_path = "${path.root}/build/receipt_worker.zip"
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

resource "aws_iam_role" "worker" {
  name               = "${local.name}-receipt-worker"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "worker_logs" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "worker_xray" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "worker" {
  # Lambda polls the queue using the FUNCTION'S role
  statement {
    sid = "ConsumeReceiptsQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.receipts.arn]
  }

  statement {
    sid       = "InspectAndDeleteReceipts"
    actions   = ["s3:GetObject", "s3:DeleteObject"]
    resources = ["${var.receipts_bucket_arn}/receipts/*"]
  }

  # 404 instead of 403 for files that were already deleted
  statement {
    sid       = "ReceiptExistenceChecks"
    actions   = ["s3:ListBucket"]
    resources = [var.receipts_bucket_arn]
  }

  # The worker only ever updates existing expenses
  statement {
    sid       = "UpdateExpenseReceiptStatus"
    actions   = ["dynamodb:UpdateItem"]
    resources = [var.table_arn]
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "receipt-worker-access"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/lambda/${local.name}-receipt-worker"
  retention_in_days = 14
}

resource "aws_lambda_function" "worker" {
  function_name    = "${local.name}-receipt-worker"
  role             = aws_iam_role.worker.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.worker.output_path
  source_code_hash = data.archive_file.worker.output_base64sha256
  timeout          = 10
  memory_size      = 256
  tracing_config {
    mode = "Active" # record an X-Ray trace for every invocation
  }
  environment {
    variables = {
      TABLE_NAME      = var.table_name
      RECEIPTS_BUCKET = var.receipts_bucket_name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_logs,
    aws_iam_role_policy.worker,
    aws_cloudwatch_log_group.worker,
  ]
}

# Connects the queue to the Lambda: Lambda polls SQS for us
resource "aws_lambda_event_source_mapping" "receipts" {
  event_source_arn = aws_sqs_queue.receipts.arn
  function_name    = aws_lambda_function.worker.arn
  batch_size       = 10

  # The worker reports WHICH messages failed, so only those are retried
  function_response_types = ["ReportBatchItemFailures"]

  # At most 5 workers in parallel, however long the queue gets
  scaling_config {
    maximum_concurrency = 5
  }

  # Lambda checks the role can read the queue when this is created
  depends_on = [aws_iam_role_policy.worker]
}

# -----------------------------------------------------------------------------
# Alarm: anything in the DLQ needs a human
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name        = "${local.name}-receipts-dlq-not-empty"
  alarm_description = "Receipt messages failed 3 times and are in the DLQ. Inspect them, fix the cause, then redrive."

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

  alarm_actions = [var.alarm_topic_arn] # email when it starts
  ok_actions    = [var.alarm_topic_arn] # email when it's resolved
}