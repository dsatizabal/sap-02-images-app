aws_region     = "us-east-1"
name_prefix    = "images-app"
allowed_origin = "http://localhost:5173"
# Replace with your pushed ECR image for the worker:
worker_image = "998401004485.dkr.ecr.us-east-1.amazonaws.com/images-app-resizer:v1"

# Optional placeholders
client_id     = "CLIENT_ID_HERE"
client_secret = "CLIENT_SECRET_HERE"
