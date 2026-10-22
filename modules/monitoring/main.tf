# =============================================================================
# MONITORING MODULE
# For now: one SNS topic that alarms publish to, with an email subscription.
# Later: dashboards and more alarms.
# =============================================================================

resource "aws_sns_topic" "alerts" {
  #checkov:skip=CKV_AWS_26:Encrypting with the AWS-managed key would stop CloudWatch alarms publishing. Would need a CMK with a CloudWatch key policy. Alerts hold no sensitive data.
  name = "${var.project_name}-${var.environment}-alerts"
}

# AWS emails a confirmation link. Alerts only arrive after you click it.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
