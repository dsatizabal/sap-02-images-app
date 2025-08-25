output "bucket_name" {
  value = aws_s3_bucket.images_bucket.bucket
}

output "api_endpoint" {
  value = aws_apigatewayv2_api.http_api.api_endpoint
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "ingest_queue_url" {
  value = aws_sqs_queue.ingest.url
}

output "resize_queue_url" {
  value = aws_sqs_queue.resize.url
}

output "kinesis_image_events" {
  value = aws_kinesis_stream.image_events_stream.name
}
