locals {
  name_prefix = var.project_name
}

################
# KMS (optional simple key for S3)
################
resource "aws_kms_key" "s3_key" {
  description             = "${local.name_prefix} S3 encryption key"
  deletion_window_in_days = 7
}

################
# S3 bucket
################
resource "aws_s3_bucket" "images_bucket" {
  bucket = "${local.name_prefix}-bucket-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "images_bucket" {
  bucket = aws_s3_bucket.images_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_versioning" "images_bucket" {
  bucket = aws_s3_bucket.images_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "images_bucket" {
  bucket = aws_s3_bucket.images_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3_key.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "images_bucket" {
  bucket                  = aws_s3_bucket.images_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "random_id" "suffix" {
  byte_length = 3
}

################
# DynamoDB tables
################
# Image metadata (single item per image; variants map stored inside item)
resource "aws_dynamodb_table" "image_metadata" {
  name         = "${local.name_prefix}-image-metadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# Counters per (imageId, size)
resource "aws_dynamodb_table" "image_counters" {
  name         = "${local.name_prefix}-image-counters"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "imageId"
  range_key    = "size"

  attribute {
    name = "imageId"
    type = "S"
  }
  attribute {
    name = "size"
    type = "S"
  }
}

################
# SQS queues
################
resource "aws_sqs_queue" "ingest_dlq" {
  name = "${local.name_prefix}-ingest-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "ingest" {
  name = "${local.name_prefix}-ingest"
  visibility_timeout_seconds = 60
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingest_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue" "resize_dlq" {
  name = "${local.name_prefix}-resize-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "resize" {
  name = "${local.name_prefix}-resize"
  visibility_timeout_seconds = 120
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.resize_dlq.arn
    maxReceiveCount     = 5
  })
}

# Allow S3 to send notifications to ingest queue
resource "aws_sqs_queue_policy" "ingest_policy" {
  queue_url = aws_sqs_queue.ingest.id
  policy    = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowS3SendMessage"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.ingest.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_s3_bucket.images_bucket.arn
        }
      }
    }]
  })
}

################
# S3 event -> SQS (ingest)
################
resource "aws_s3_bucket_notification" "images_bucket" {
  bucket = aws_s3_bucket.images_bucket.id

  queue {
    queue_arn     = aws_sqs_queue.ingest.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "images/"
    filter_suffix = "/original"
  }

  depends_on = [aws_sqs_queue_policy.ingest_policy]
}

################
# Kinesis streams
################
resource "aws_kinesis_stream" "image_events_stream" {
  name             = "${local.name_prefix}-image-events"
  shard_count      = 1
  retention_period = 24
  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}

# For CloudFront real-time logs
resource "aws_kinesis_stream" "cf_rt_logs" {
  name             = "${local.name_prefix}-cf-rt-logs"
  shard_count      = 1
  retention_period = 24
  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}

################
# Lambda: uploader (pre-signed POST + metadata)
################
resource "aws_iam_role" "lambda_uploader_role" {
  name = "${local.name_prefix}-lambda-uploader-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_uploader_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_uploader_policy" {
  name        = "${local.name_prefix}-lambda-uploader-policy"
  description = "Allow presign put, DDB write, Kinesis put"
  policy      = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"],
        Resource = ["${aws_s3_bucket.images_bucket.arn}/*"]
      },
      {
        Effect   = "Allow",
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"],
        Resource = [aws_dynamodb_table.image_metadata.arn]
      },
      {
        Effect   = "Allow",
        Action   = ["kinesis:PutRecord", "kinesis:PutRecords"],
        Resource = [aws_kinesis_stream.image_events_stream.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_uploader_attach" {
  role       = aws_iam_role.lambda_uploader_role.name
  policy_arn = aws_iam_policy.lambda_uploader_policy.arn
}

resource "aws_lambda_function" "uploader" {
  function_name = "${local.name_prefix}-init-upload"
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  role          = aws_iam_role.lambda_uploader_role.arn
  filename      = var.lambda_uploader_zip_path
  timeout       = 10
  environment {
    variables = {
      BUCKET_NAME            = aws_s3_bucket.images_bucket.bucket
      DDB_TABLE_METADATA     = aws_dynamodb_table.image_metadata.name
      KINESIS_STREAM_NAME    = aws_kinesis_stream.image_events_stream.name
      URL_EXPIRY_SECONDS     = "900"
      MAX_SIZE_MB            = "25"
      DEFAULT_SIZES          = join(",", var.image_sizes)
      REGION                 = var.region
    }
  }
  depends_on = [aws_iam_role_policy_attachment.lambda_uploader_attach]
}

################
# API Gateway HTTP API -> Lambda uploader
################
resource "aws_apigatewayv2_api" "http_api" {
  name          = "${local.name_prefix}-http-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "uploader_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.uploader.arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "init_upload_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /images/init-upload"
  target    = "integrations/${aws_apigatewayv2_integration.uploader_integration.id}"
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.uploader.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

################
# CloudFront + OAC + Real-time logs + Lambda@Edge
################
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${local.name_prefix}-oac"
  description                       = "OAC for S3 origin"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${local.name_prefix} CDN"
  default_root_object = ""

  origin {
    domain_name              = aws_s3_bucket.images_bucket.bucket_regional_domain_name
    origin_id                = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    lambda_function_association {
      event_type   = "origin-response"
      lambda_arn   = aws_lambda_function.lambda_edge_use1.qualified_arn
      include_body = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Real-time log config
resource "aws_cloudfront_realtime_log_config" "rtlog" {
  name = "${local.name_prefix}-rtlog"
  sampling_rate = 100
  fields = ["timestamp", "c-ip", "cs-uri-stem", "sc-status", "cs-method", "sc-bytes"]
  endpoint {
    stream_type = "Kinesis"
    kinesis_stream_config {
      role_arn   = aws_iam_role.cf_rt_role.arn
      stream_arn = aws_kinesis_stream.cf_rt_logs.arn
    }
  }
}

resource "aws_iam_role" "cf_rt_role" {
  name = "${local.name_prefix}-cf-rt-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "cloudfront.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cf_rt_policy" {
  name = "${local.name_prefix}-cf-rt-policy"
  role = aws_iam_role.cf_rt_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow",
      Action = ["kinesis:DescribeStream", "kinesis:PutRecord", "kinesis:PutRecords"],
      Resource = aws_kinesis_stream.cf_rt_logs.arn
    }]
  })
}

# Attach CF real-time logs to distribution
resource "aws_cloudfront_monitoring_subscription" "monitoring" {
  distribution_id = aws_cloudfront_distribution.cdn.id
  realtime_metrics_subscription_config {
    realtime_metrics_subscription_status = "Enabled"
  }
}

################
# Lambda@Edge (must be in us-east-1)
################
resource "aws_iam_role" "lambda_edge_role_use1" {
  provider = aws.use1
  name     = "${local.name_prefix}-edge-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_edge_basic_use1" {
  provider  = aws.use1
  role      = aws_iam_role.lambda_edge_role_use1.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_edge_ddb_use1" {
  provider = aws.use1
  name     = "${local.name_prefix}-edge-ddb-policy"
  policy   = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow",
      Action = ["dynamodb:GetItem"],
      Resource = "${aws_dynamodb_table.image_counters.arn}"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_edge_ddb_attach_use1" {
  provider  = aws.use1
  role      = aws_iam_role.lambda_edge_role_use1.name
  policy_arn = aws_iam_policy.lambda_edge_ddb_use1.arn
}

resource "aws_lambda_function" "lambda_edge_use1" {
  provider      = aws.use1
  function_name = "${local.name_prefix}-edge-headers"
  role          = aws_iam_role.lambda_edge_role_use1.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  filename      = var.lambda_edge_zip_path
  publish       = true
  timeout       = 5

  environment {
    variables = {
      DDB_COUNTERS_TABLE = aws_dynamodb_table.image_counters.name
      REGION             = var.region
    }
  }
  depends_on = [aws_iam_role_policy_attachment.lambda_edge_ddb_attach_use1]
}

################
# Minimal VPC (public subnets) for ECS Fargate
################
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags = { Name = "${local.name_prefix}-public-a" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[1]
  tags = { Name = "${local.name_prefix}-public-b" }
}

data "aws_availability_zones" "available" {}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "a" {
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public_a.id
}

resource "aws_route_table_association" "b" {
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public_b.id
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${local.name_prefix}-ecs-tasks-sg"
  vpc_id      = aws_vpc.main.id
  description = "Allow all egress"
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

################
# ECS cluster, task, and service
################
resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-cluster"
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name_prefix}-worker"
  retention_in_days = 7
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${local.name_prefix}-ecs-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec_attach" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_role" {
  name = "${local.name_prefix}-ecs-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "ecs_task_policy" {
  name   = "${local.name_prefix}-ecs-task-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow",
        Action = ["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],
        Resource = [aws_sqs_queue.ingest.arn, aws_sqs_queue.resize.arn]
      },
      {
        Effect = "Allow",
        Action = ["s3:GetObject","s3:PutObject","s3:ListBucket"],
        Resource = [
          aws_s3_bucket.images_bucket.arn,
          "${aws_s3_bucket.images_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = ["dynamodb:UpdateItem","dynamodb:GetItem","dynamodb:PutItem"],
        Resource = [aws_dynamodb_table.image_metadata.arn, aws_dynamodb_table.image_counters.arn]
      },
      {
        Effect = "Allow",
        Action = ["kinesis:PutRecord","kinesis:PutRecords"],
        Resource = [aws_kinesis_stream.image_events_stream.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_attach" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.ecs_task_policy.arn
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.name_prefix}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([{
    name      = "worker"
    image     = var.ecs_worker_image
    essential = true
    environment = [
      { name = "REGION", value = var.region },
      { name = "BUCKET_NAME", value = aws_s3_bucket.images_bucket.bucket },
      { name = "DDB_TABLE_METADATA", value = aws_dynamodb_table.image_metadata.name },
      { name = "DDB_TABLE_COUNTERS", value = aws_dynamodb_table.image_counters.name },
      { name = "INGEST_QUEUE_URL", value = aws_sqs_queue.ingest.url },
      { name = "RESIZE_QUEUE_URL", value = aws_sqs_queue.resize.url },
      { name = "DEFAULT_SIZES", value = join(",", var.image_sizes) }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "worker" {
  name            = "${local.name_prefix}-worker-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    assign_public_ip = true
    subnets          = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    security_groups  = [aws_security_group.ecs_tasks.id]
  }
}
