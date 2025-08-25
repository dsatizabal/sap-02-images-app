# Lambda Uploader (Python)

Exposes `POST /images/init-upload` via API Gateway.
- Generates an imageId and **pre-signed POST** (URL + form fields) for `images/{id}/original`
- Creates a DynamoDB item with status `PENDING`
- Emits a small Kinesis event for observability

## Zip

This Lambda uses only the built-in `boto3` in the AWS runtime, so no extra dependencies.

```bash
zip -j lambda_uploader.zip handler.py
```
