variable "name_prefix" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "allowed_origin" {
  type = string
}

variable "lambda_zip" {
  type    = string
  default = "./artifacts/lambda-uploader.zip"
}
