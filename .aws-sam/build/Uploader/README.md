# Lambda Uploader (SSM-enabled)

- Reads config from SSM when `SSM_PARAM_PATH` is set (e.g., `/img-pipeline/dev/uploader/`), else from env.
- Requires IAM: `ssm:GetParametersByPath` on the path, and `kms:Decrypt` if SecureString.

SSM keys expected (leaves):
- bucket_name
- ddb_table_metadata
- kinesis_stream_name (optional)
- region
- url_expiry_seconds
- max_size_mb
- default_sizes

Zip:
```
zip -j lambda_uploader_ssm.zip handler.py
```
