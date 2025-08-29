output "api_base_url" {
  value = module.api.api_endpoint
}

output "bucket_name" {
  value = module.bucket.name
}

output "bucket_arn" {
  value = module.bucket.arn
}

output "bucket_id" {
  value = module.bucket.id
}

output "ddb_table_name" {
  value = module.table.name
}

output "ddb_table_arn" {
  value = module.table.arn
}

output "appconfig_application_name" {
  value = module.appconfig.application_name
}

output "appconfig_application_id" {
  value = module.appconfig.application_id
}

output "appconfig_environment_id" {
  value = module.appconfig.environment_id
}
