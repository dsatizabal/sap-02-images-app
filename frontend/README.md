# Frontend (React + Vite)

Minimal UI to:
1) Call `POST /images/init-upload` (Lambda uploader via API Gateway)
2) Perform presigned POST to S3 to upload the original image
3) Show CloudFront links for expected variants

Configure `src/config.js` with your API base and CloudFront domain.

Run:
```
npm install
npm run dev
```
