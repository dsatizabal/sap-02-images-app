data "aws_caller_identity" "current" {}

resource "aws_sqs_queue" "ingest_dlq" { name = "${var.name_prefix}-ingestion-dlq" }

resource "aws_sqs_queue" "ingest" {
  name                       = "${var.name_prefix}-ingestion"
  visibility_timeout_seconds = 120
  receive_wait_time_seconds  = 20
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingest_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue" "resize" {
  name                       = "${var.name_prefix}-resizer"
  visibility_timeout_seconds = 180
  receive_wait_time_seconds  = 20
}

resource "aws_sqs_queue_policy" "ingest" {
  queue_url = aws_sqs_queue.ingest.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "AllowS3Send",
      Effect    = "Allow",
      Principal = { Service = "s3.amazonaws.com" },
      Action    = "sqs:SendMessage",
      Resource  = aws_sqs_queue.ingest.arn,
      Condition = {
        ArnEquals    = { "aws:SourceArn" : var.bucket_arn },
        StringEquals = { "aws:SourceAccount" : data.aws_caller_identity.current.account_id }
      }
    }]
  })
}
