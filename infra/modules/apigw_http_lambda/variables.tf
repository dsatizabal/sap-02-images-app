variable "name_prefix" {
  type = string
}
variable "lambda_arn" {
  type = string
}

variable "route_key" {
  type    = string
  default = "POST /images/init-upload"
}

variable "allowed_origin" {
  type    = string
  default = "*"
}
