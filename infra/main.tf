module "uploader" {
  source         = "./components/uploader"
  name_prefix    = var.name_prefix
  aws_region     = var.aws_region
  allowed_origin = var.allowed_origin
}

module "resizer" {
  source                     = "./components/resizer"
  name_prefix                = var.name_prefix
  aws_region                 = var.aws_region
  bucket_name                = module.uploader.bucket_name
  bucket_arn                 = module.uploader.bucket_arn
  bucket_id                  = module.uploader.bucket_id
  table_name                 = module.uploader.ddb_table_name
  table_arn                  = module.uploader.ddb_table_arn
  worker_image               = var.worker_image
  appconfig_application_name = module.uploader.appconfig_application_name
  appconfig_application_id   = module.uploader.appconfig_application_id
  appconfig_environment_id   = module.uploader.appconfig_environment_id
}

