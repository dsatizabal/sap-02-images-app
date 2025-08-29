module "queues" {
  source      = "../../modules/sqs_queues"
  name_prefix = var.name_prefix
  bucket_arn  = var.bucket_arn
}

resource "aws_s3_bucket_notification" "ingest" {
  bucket = var.bucket_id
  queue {
    queue_arn     = module.queues.ingest_queue_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "images/"
  }
}

module "appconfig_data" {
  source                   = "../../modules/appconfig_data"
  appconfig_application_id = var.appconfig_application_id
  appconfig_environment_id = var.appconfig_environment_id
  profile_name             = "resizer"
  config_json = jsonencode({
    bucket_name         = var.bucket_name
    ddb_table_metadata  = var.table_name
    ingest_queue_url    = module.queues.ingest_queue_url
    resize_queue_url    = module.queues.resize_queue_url
    region              = var.aws_region
    default_sizes       = ["thumb", "medium", "large"]
    kinesis_stream_name = ""
  })
}

module "ecs" {
  source      = "../../modules/ecs_service"
  name_prefix = var.name_prefix
  region      = var.aws_region
  image       = var.worker_image

  appconfig_app     = var.appconfig_application_name
  appconfig_env     = "dev"
  appconfig_profile = "resizer"

  bucket_arn       = var.bucket_arn
  bucket_name      = var.bucket_name
  table_arn        = var.table_arn
  table_name       = var.table_name
  ingest_queue_arn = module.queues.ingest_queue_arn
  ingest_queue_url = module.queues.ingest_queue_url
  resize_queue_arn = module.queues.resize_queue_arn
  resize_queue_url = module.queues.resize_queue_url
}
