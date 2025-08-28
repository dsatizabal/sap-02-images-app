# ECS Worker (AppConfig Extension + env fallback) — original.* support

Loads config from AWS AppConfig Lambda Extension first; falls back to ENV vars.

Required config (AppConfig JSON or ENV):
- bucket_name / BUCKET_NAME
- ddb_table_metadata / DDB_TABLE_METADATA
- ingest_queue_url / INGEST_QUEUE_URL
- resize_queue_url / RESIZE_QUEUE_URL
Optional: region, default_sizes, ddb_table_counters, kinesis_stream_name

Example AppConfig JSON:
{
  "bucket_name": "images-app-uploader",
  "ddb_table_metadata": "img-pipeline-image-metadata",
  "ingest_queue_url": "https://sqs.us-east-1.amazonaws.com/123456789012/ingest-queue",
  "resize_queue_url": "https://sqs.us-east-1.amazonaws.com/123456789012/resize-queue",
  "region": "us-east-1",
  "default_sizes": ["thumb","medium","large"],
  "kinesis_stream_name": ""
}

Build & run locally:
  docker build -t img-worker:latest .
  docker run --rm -it     -e APPCONFIG_APPLICATION=images-app     -e APPCONFIG_ENVIRONMENT=dev     -e APPCONFIG_PROFILE=dev     # or provide env directly:
    -e REGION=us-east-1     -e BUCKET_NAME=images-app-uploader     -e DDB_TABLE_METADATA=img-pipeline-image-metadata     -e INGEST_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/123/ingest     -e RESIZE_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/123/resize     img-worker:latest

S3 notifications:
If you filtered by suffix /original, remove the suffix (or match original.*). The worker accepts keys whose final path segment starts with "original".
