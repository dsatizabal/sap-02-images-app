output "ingest_queue_url" { value = aws_sqs_queue.ingest.id }
output "resize_queue_url" { value = aws_sqs_queue.resize.id }
output "ingest_queue_arn" { value = aws_sqs_queue.ingest.arn }
output "resize_queue_arn" { value = aws_sqs_queue.resize.arn }
