output "api_base_url" { value = module.uploader.api_base_url }
output "bucket_name" { value = module.uploader.bucket_name }
output "ddb_table_name" { value = module.uploader.ddb_table_name }
output "ingest_queue_url" { value = module.resizer.ingest_queue_url }
output "resize_queue_url" { value = module.resizer.resize_queue_url }
output "ecs_service_name" { value = module.resizer.service_name }
output "ecs_cluster_name" { value = module.resizer.cluster_name }
