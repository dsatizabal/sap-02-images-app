variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "image" {
  type = string
}

variable "appconfig_app" {
  type = string
}

variable "appconfig_env" {
  type = string
}

variable "appconfig_profile" {
  type = string
}

variable "bucket_arn" {
  type = string
}

variable "bucket_name" {
  type = string
}

variable "table_arn" {
  type = string
}

variable "table_name" {
  type = string
}

variable "ingest_queue_arn" {
  type = string
}

variable "ingest_queue_url" {
  type = string
}

variable "resize_queue_arn" {
  type = string
}

variable "resize_queue_url" {
  type = string
}
