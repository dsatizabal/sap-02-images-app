# AWS Image Pipeline (Terraform)

This Terraform stack sets up:
- S3 bucket (private, SSE-KMS)
- SQS queues (ingest + resize + DLQs)
- DynamoDB tables (image_metadata, image_counters)
- Kinesis streams (image-events, cf-rt-logs)
- Lambda (Python) for `POST /images/init-upload` via API Gateway (HTTP API)
- CloudFront distribution with OAC and Lambda@Edge (Node.js) for response headers
- ECS Fargate worker service (polls SQS, reads/writes S3, updates DynamoDB)

## Usage

1. Build code packages:
   - **Lambda uploader**: zip as `lambda_uploader.zip` (see `../lambda-uploader`)
   - **Lambda@Edge**: zip as `lambda_edge.zip` after `npm ci` (see `../lambda-edge`)
   - **ECS worker**: build & push to ECR, then set `var.ecs_worker_image`.

2. Adjust variables in `variables.tf` or pass `-var` overrides:
   - `region`, `project_name`, `lambda_uploader_zip_path`, `lambda_edge_zip_path`, `ecs_worker_image`

3. Init & apply:
   ```bash
   terraform init
   terraform apply
   ```

4. Test the upload init endpoint:
   ```bash
   curl -X POST $(terraform output -raw api_endpoint)/images/init-upload
   ```
   It returns `imageId` and a **pre-signed POST** (URL + form fields). Use the form to upload the original image to key `images/{imageId}/original`.

## Notes
- Lambda@Edge functions must live in **us-east-1**; this stack sets a second provider for that.
- ECS tasks run in **public subnets** with public IP to simplify egress.
- CloudFront RT logs stream to Kinesis; wire a separate Lambda consumer to aggregate counters into DynamoDB (exercise left for you).
