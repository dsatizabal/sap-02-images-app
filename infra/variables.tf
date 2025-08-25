variable "project_name" {
  type        = string
  description = "Project name prefix for resource naming."
  default     = "img-pipeline"
}

variable "region" {
  type        = string
  description = "AWS region to deploy the stack (except Lambda@Edge which must be us-east-1)."
  default     = "us-east-1"
}

variable "lambda_uploader_zip_path" {
  type        = string
  description = "Path to the zipped Lambda uploader package."
  default     = "../lambda-uploader/lambda_uploader.zip"
}

variable "lambda_edge_zip_path" {
  type        = string
  description = "Path to the zipped Lambda@Edge package (Node.js). Must be deployed in us-east-1."
  default     = "../lambda-edge/lambda_edge.zip"
}

variable "ecs_worker_image" {
  type        = string
  description = "ECR image URI for the ECS worker (e.g., 123456789012.dkr.ecr.us-east-1.amazonaws.com/img-worker:latest)."
  default     = "REPLACE_WITH_ECR_IMAGE_URI"
}

variable "image_sizes" {
  type        = list(string)
  description = "Variants to generate."
  default     = ["thumb","medium","large"]
}
