output "ingest_queue_url" {
  value = module.queues.ingest_queue_url
}

output "resize_queue_url" {
  value = module.queues.resize_queue_url
}

output "cluster_name" {
  value = module.ecs.cluster_name
}

output "service_name" {
  value = module.ecs.service_name
}
