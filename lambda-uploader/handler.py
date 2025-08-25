import os, json, uuid, time
import boto3

BUCKET = os.environ["BUCKET_NAME"]
TABLE  = os.environ["DDB_TABLE_METADATA"]
STREAM = os.environ.get("KINESIS_STREAM_NAME", "")
REGION = os.environ.get("REGION", "us-east-1")
URL_EXPIRY = int(os.environ.get("URL_EXPIRY_SECONDS", "900"))
MAX_SIZE_MB = int(os.environ.get("MAX_SIZE_MB", "25"))
DEFAULT_SIZES = [s.strip() for s in os.environ.get("DEFAULT_SIZES","thumb,medium,large").split(",") if s.strip()]

s3 = boto3.client("s3", region_name=REGION)
ddb = boto3.client("dynamodb", region_name=REGION)
kin = boto3.client("kinesis", region_name=REGION)

def lambda_handler(event, context):
    # Generate id and presigned POST (to enforce content-length-range)
    image_id = uuid.uuid4().hex[:26]  # pseudo-ULID length
    key = f"images/{image_id}/original"

    conditions = [
        ["content-length-range", 1, MAX_SIZE_MB * 1024 * 1024],
        {"key": key}
    ]
    fields = {"key": key}

    presigned = s3.generate_presigned_post(
        Bucket=BUCKET,
        Key=key,
        Fields=fields,
        Conditions=conditions,
        ExpiresIn=URL_EXPIRY
    )

    # Create metadata item
    now = int(time.time())
    ddb.put_item(
        TableName=TABLE,
        Item={
            "id": {"S": image_id},
            "status": {"S": "PENDING"},
            "created_at": {"N": str(now)},
            "variants": {"M": {}}
        }
    )

    if STREAM:
        try:
            kin.put_record(StreamName=STREAM, PartitionKey=image_id,
                           Data=json.dumps({"imageId": image_id, "action": "init"}))
        except Exception:
            pass

    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({
            "imageId": image_id,
            "bucket": BUCKET,
            "upload": presigned,
            "sizes": DEFAULT_SIZES
        })
    }
