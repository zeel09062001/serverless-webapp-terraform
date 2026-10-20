output "function_name" {
  value = aws_lambda_function.report.function_name
}

output "schedule_name" {
  value = aws_scheduler_schedule.monthly.name
}