output "table_name" {
  description = "Name of the expenses table (passed to Lambdas as an env variable)"
  value       = aws_dynamodb_table.expenses.name
}

output "table_arn" {
  description = "ARN of the table (used in IAM policies)"
  value       = aws_dynamodb_table.expenses.arn
}

output "index_arns" {
  description = "ARN pattern covering all indexes of the table (used in IAM policies)"
  value       = "${aws_dynamodb_table.expenses.arn}/index/*"
}