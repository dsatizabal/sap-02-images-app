variable "aws_region" {
  description = "AWS region"
  type        = string
}

# Optional placeholders if your tooling requires them (not used by provider)
variable "client_id" {
  type      = string
  default   = null
  sensitive = true
}

variable "client_secret" {
  type      = string
  default   = null
  sensitive = true
}

variable "name_prefix" {
  type    = string
  default = "images-app"
}

variable "allowed_origin" {
  type    = string
  default = "http://localhost:5173"
}

variable "worker_image" {
  type = string
}
