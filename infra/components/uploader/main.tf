locals {
  bucket_name   = "${var.name_prefix}-uploader"
  table_name    = "${var.name_prefix}-metadata"
  env_name      = "dev"
  profile_name  = "uploader"
  default_sizes = ["thumb", "medium", "large"]
  url_expiry    = 900
  max_size_mb   = 25
}

module "bucket" {
  source         = "../../modules/s3_bucket"
  name           = local.bucket_name
  allowed_origin = var.allowed_origin
}

module "table" {
  source = "../../modules/dynamodb_table"
  name   = local.table_name
}

module "appconfig" {
  source      = "../../modules/appconfig"
  name_prefix = var.name_prefix
  env_name    = local.env_name
}

module "appconfig_data" {
  source                   = "../../modules/appconfig_data"
  appconfig_application_id = module.appconfig.application_id
  appconfig_environment_id = module.appconfig.environment_id
  profile_name             = local.profile_name
  config_json = jsonencode({
    bucket_name         = module.bucket.name
    ddb_table_metadata  = module.table.name
    kinesis_stream_name = ""
    region              = var.aws_region
    url_expiry_seconds  = local.url_expiry
    max_size_mb         = local.max_size_mb
    default_sizes       = local.default_sizes
  })
}

resource "aws_iam_policy" "ddb_write" {
  name = "${var.name_prefix}-uploader-ddb-write"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"], Resource = module.table.arn }
    ]
  })
}

module "lambda" {
  source      = "../../modules/lambda_function"
  name        = "${var.name_prefix}-uploader"
  filename    = var.lambda_zip
  handler     = "handler.lambda_handler"
  runtime     = "python3.13"
  timeout     = 10
  memory_size = 256
  env = {
    APPCONFIG_APPLICATION = module.appconfig.application_name
    APPCONFIG_ENVIRONMENT = module.appconfig.environment_name
    APPCONFIG_PROFILE     = module.appconfig_data.profile_name
    REGION                = var.aws_region
  }
}

resource "aws_iam_role_policy_attachment" "lambda_ddb" {
  role       = module.lambda.role_name
  policy_arn = aws_iam_policy.ddb_write.arn
}

module "api" {
  source         = "../../modules/apigw_http_lambda"
  name_prefix    = var.name_prefix
  lambda_arn     = module.lambda.function_arn
  allowed_origin = var.allowed_origin
  route_key      = "POST /images/init-upload"
}

# Allow the uploader Lambda to sign presigned POSTs that PUT to your bucket
resource "aws_iam_policy" "uploader_s3_put" {
  name = "${var.name_prefix}-uploader-s3-put"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject"],
        Resource = "${module.bucket.arn}/*"
      }
    ]
  })
}

# Attach to the Lambda role the module created
resource "aws_iam_role_policy_attachment" "uploader_s3_put" {
  role       = module.lambda.role_name
  policy_arn = aws_iam_policy.uploader_s3_put.arn
}
