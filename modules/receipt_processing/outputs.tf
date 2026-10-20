output "queue_url" {
  value = aws_sqs_queue.receipts.id
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.id
}

output "worker_function_name" {
  value = aws_lambda_function.worker.function_name
}
output "queue_name" {
  value = aws_sqs_queue.receipts.name
}

output "dlq_name" {
  value = aws_sqs_queue.dlq.name
}