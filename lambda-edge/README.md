# Lambda@Edge (Node.js)

Adds response headers with counters from DynamoDB:
- `x-image-id`, `x-image-size`, `x-views`, `x-pixels-viewed`

**Note:** Lambda@Edge supports Node.js best. Python support/runtimes at the edge are limited and change over time, so this sample uses Node.js 18.x for reliability.

## Build zip

```bash
npm ci
zip -r lambda_edge.zip index.js node_modules package.json package-lock.json
```

Upload/deploy via Terraform by pointing `var.lambda_edge_zip_path` to the zip file.
