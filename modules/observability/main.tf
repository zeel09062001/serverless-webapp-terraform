# =============================================================================
# OBSERVABILITY MODULE
# Alarms on what users feel (API errors and latency), alarms that explain
# why (Lambda errors and throttles), one dashboard, and saved log queries.
# Depends on every other module, so nothing may depend on it.
# =============================================================================

locals {
  name              = "${var.project_name}-${var.environment}"
  lambda_log_groups = [for fn in values(var.lambda_function_names) : "/aws/lambda/${fn}"]
}

# -----------------------------------------------------------------------------
# Symptom alarms: what users actually experience
# -----------------------------------------------------------------------------

# Error RATE, not error count, and only once there's enough traffic
# for a percentage to mean something
resource "aws_cloudwatch_metric_alarm" "api_error_rate" {
  alarm_name          = "${local.name}-api-5xx-rate"
  alarm_description   = "More than 5% of API requests failed with a server error (5xx) in 5 minutes. Check the 'API errors' log query and the Lambda logs."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "5xx"
      dimensions  = { ApiId = var.api_id }
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "Count"
      dimensions  = { ApiId = var.api_id }
      period      = 300
      stat        = "Sum"
    }
  }

  # Metric math: a percentage, but 0 when there were fewer than 10 requests
  metric_query {
    id          = "error_rate"
    expression  = "IF(requests >= 10, 100 * errors / requests, 0)"
    label       = "5xx error rate (%)"
    return_data = true
  }

  alarm_actions = [var.alarm_topic_arn]
  ok_actions    = [var.alarm_topic_arn]
}

# p95, not the average: the average hides the slowest users
resource "aws_cloudwatch_metric_alarm" "api_latency_p95" {
  alarm_name          = "${local.name}-api-latency-p95"
  alarm_description   = "95% of API requests should finish within 1 second. Fires when p95 is above 1s in 2 of the last 3 five-minute periods. Check the 'Slowest API requests' query."
  namespace           = "AWS/ApiGateway"
  metric_name         = "Latency"
  dimensions          = { ApiId = var.api_id }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2 # one slow spike alone won't page anyone
  threshold           = 1000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.alarm_topic_arn]
  ok_actions    = [var.alarm_topic_arn]
}

# -----------------------------------------------------------------------------
# Cause alarms: help explain WHY something is wrong
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = var.lambda_function_names

  alarm_name          = "${local.name}-${each.key}-errors"
  alarm_description   = "The ${each.key} Lambda failed with an unhandled error. Check its logs."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.alarm_topic_arn]
  ok_actions    = [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = var.lambda_function_names

  alarm_name          = "${local.name}-${each.key}-throttles"
  alarm_description   = "The ${each.key} Lambda was throttled: it hit a concurrency limit and requests were refused or delayed."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.alarm_topic_arn]
  ok_actions    = [var.alarm_topic_arn]
}

# -----------------------------------------------------------------------------
# Dashboard: the whole system on one screen
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "API requests and errors"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", var.api_id, { label = "Requests" }],
            ["AWS/ApiGateway", "4xx", "ApiId", var.api_id, { label = "4xx (client errors)" }],
            ["AWS/ApiGateway", "5xx", "ApiId", var.api_id, { label = "5xx (server errors)" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "API latency (ms)"
          region = var.aws_region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { stat = "p50", label = "p50 (typical)" }],
            ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { stat = "p95", label = "p95" }],
            ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { stat = "p99", label = "p99 (slowest 1%)" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Lambda errors"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            for key, fn in var.lambda_function_names :
            ["AWS/Lambda", "Errors", "FunctionName", fn, { label = key }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Lambda duration p95 (ms)"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "p95"
          period = 300
          metrics = [
            for key, fn in var.lambda_function_names :
            ["AWS/Lambda", "Duration", "FunctionName", fn, { label = key }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "Queues"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.receipts_queue_name, { label = "Receipts waiting" }],
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", var.receipts_queue_name, { label = "Oldest receipt waiting (s)", yAxis = "right" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.receipts_dlq_name, { label = "Receipts DLQ" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.report_dlq_name, { label = "Monthly report DLQ" }],
          ]
        }
      },
      {
        type = "alarm", x = 12, y = 12, width = 12, height = 6
        properties = {
          title = "Alarm status"
          alarms = concat(
            [aws_cloudwatch_metric_alarm.api_error_rate.arn, aws_cloudwatch_metric_alarm.api_latency_p95.arn],
            [for alarm in aws_cloudwatch_metric_alarm.lambda_errors : alarm.arn],
            [for alarm in aws_cloudwatch_metric_alarm.lambda_throttles : alarm.arn],
          )
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Saved Logs Insights queries: the questions you'll ask during an incident
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_query_definition" "api_errors" {
  name            = "${local.name}/API errors"
  log_group_names = [var.api_access_log_group_name]
  query_string    = <<-EOT
    fields @timestamp, routeKey, status, latencyMs, userId, integrationError, authorizerError
    | filter status >= 400
    | sort @timestamp desc
    | limit 50
  EOT
}

resource "aws_cloudwatch_query_definition" "api_slowest" {
  name            = "${local.name}/Slowest API requests"
  log_group_names = [var.api_access_log_group_name]
  query_string    = <<-EOT
    fields @timestamp, routeKey, status, latencyMs, integrationLatencyMs, userId
    | sort latencyMs desc
    | limit 20
  EOT
}

resource "aws_cloudwatch_query_definition" "cold_starts" {
  name            = "${local.name}/Lambda cold starts"
  log_group_names = local.lambda_log_groups
  query_string    = <<-EOT
    filter @type = "REPORT"
    | stats count(*) as invocations,
            count(@initDuration) as coldStarts,
            avg(@initDuration) as avgInitMs,
            pct(@duration, 95) as p95DurationMs
      by @log
  EOT
}

resource "aws_cloudwatch_query_definition" "lambda_errors" {
  name            = "${local.name}/Lambda errors"
  log_group_names = local.lambda_log_groups
  query_string    = <<-EOT
    fields @timestamp, @log, @message
    | filter @message like /ERROR|Traceback|Exception/
    | sort @timestamp desc
    | limit 50
  EOT
}