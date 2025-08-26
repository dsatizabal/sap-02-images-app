import os, json, time, logging, io
import boto3
from PIL import Image
from urllib.parse import unquote_plus
import urllib.request
import signal
import sys

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("worker")

def _load_appconfig_extension():
    app = os.getenv("APPCONFIG_APPLICATION")
    env = os.getenv("APPCONFIG_ENVIRONMENT")
    profile = os.getenv("APPCONFIG_PROFILE")

    if not (app and env and profile):
        return {}

    base = os.getenv("APPCONFIG_BASE_URL", "http://localhost:2772")
    url  = f"{base}/applications/{app}/environments/{env}/configurations/{profile}"

    try:
        with urllib.request.urlopen(url, timeout=1.5) as r:
            txt = r.read().decode("utf-8")
            return json.loads(txt)
    except Exception as e:
        log.warning("AppConfig extension not available (%s); using env fallback", e)

        return {}

def _normalize(cfg):
    def val(*keys, default=None):
        for k in keys:
            if k in cfg and cfg[k] not in (None, ""):
                return cfg[k]
        return default

    region = val("region", "REGION", default=os.getenv("REGION", "us-east-1"))
    bucket = val("bucket_name", "BUCKET_NAME", default=os.getenv("BUCKET_NAME"))
    ddb_meta = val("ddb_table_metadata", "DDB_TABLE_METADATA", default=os.getenv("DDB_TABLE_METADATA"))
    ddb_counters = val("ddb_table_counters", "DDB_TABLE_COUNTERS", default=os.getenv("DDB_TABLE_COUNTERS", ""))
    ingest_q = val("ingest_queue_url", "INGEST_QUEUE_URL", default=os.getenv("INGEST_QUEUE_URL"))
    resize_q = val("resize_queue_url", "RESIZE_QUEUE_URL", default=os.getenv("RESIZE_QUEUE_URL"))
    kinesis_stream = val("kinesis_stream_name", "KINESIS_STREAM_NAME", default=os.getenv("KINESIS_STREAM_NAME", ""))

    default_sizes = val("default_sizes", "DEFAULT_SIZES", default=os.getenv("DEFAULT_SIZES", "thumb,medium,large"))

    if isinstance(default_sizes, str):
        default_sizes = [s.strip() for s in default_sizes.split(",") if s.strip()]

    cfg_norm = {
        "REGION": region,
        "BUCKET_NAME": bucket,
        "DDB_TABLE_METADATA": ddb_meta,
        "DDB_TABLE_COUNTERS": ddb_counters,
        "INGEST_QUEUE_URL": ingest_q,
        "RESIZE_QUEUE_URL": resize_q,
        "KINESIS_STREAM_NAME": kinesis_stream,
        "DEFAULT_SIZES": default_sizes,
    }

    missing = [k for k in ("BUCKET_NAME", "DDB_TABLE_METADATA", "INGEST_QUEUE_URL", "RESIZE_QUEUE_URL") if not cfg_norm.get(k)]

    if missing:
        raise RuntimeError(f"Missing required config: {missing}. Provide via AppConfig or ENV.")

    return cfg_norm

def load_config():
    cfg = _load_appconfig_extension()

    env_overrides = {
        "BUCKET_NAME": os.getenv("BUCKET_NAME"),
        "DDB_TABLE_METADATA": os.getenv("DDB_TABLE_METADATA"),
        "DDB_TABLE_COUNTERS": os.getenv("DDB_TABLE_COUNTERS"),
        "INGEST_QUEUE_URL": os.getenv("INGEST_QUEUE_URL"),
        "RESIZE_QUEUE_URL": os.getenv("RESIZE_QUEUE_URL"),
        "KINESIS_STREAM_NAME": os.getenv("KINESIS_STREAM_NAME"),
        "REGION": os.getenv("REGION"),
        "DEFAULT_SIZES": os.getenv("DEFAULT_SIZES"),
    }

    for k, v in env_overrides.items():
        if v not in (None, ""):
            cfg[k] = v

    return _normalize(cfg)

_CFG = load_config()
REGION = _CFG["REGION"]
BUCKET = _CFG["BUCKET_NAME"]
DDB_META = _CFG["DDB_TABLE_METADATA"]
DDB_COUNTERS = _CFG["DDB_TABLE_COUNTERS"]
INGEST_Q_URL = _CFG["INGEST_QUEUE_URL"]
RESIZE_Q_URL = _CFG["RESIZE_QUEUE_URL"]
KINESIS_STREAM_NAME = _CFG["KINESIS_STREAM_NAME"]
DEFAULT_SIZES = _CFG["DEFAULT_SIZES"]

log.info("Config: region=%s bucket=%s table=%s ingestQ=%s resizeQ=%s sizes=%s",
         REGION, BUCKET, DDB_META, INGEST_Q_URL.rsplit('/',1)[-1], RESIZE_Q_URL.rsplit('/',1)[-1], DEFAULT_SIZES)

sqs = boto3.client("sqs", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)
ddb = boto3.client("dynamodb", region_name=REGION)
kin = boto3.client("kinesis", region_name=REGION)

def receive(queue_url):
    return sqs.receive_message(
        QueueUrl=queue_url,
        MaxNumberOfMessages=5,
        WaitTimeSeconds=20,
        VisibilityTimeout=60
    ).get("Messages", [])

def delete(queue_url, receipt):
    sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt)

def _is_original_key(key: str) -> bool:
    last = key.rsplit('/', 1)[-1]
    return last.startswith("original")

def handle_s3_ingest(evt):
    for rec in evt["Records"]:
        b = rec["s3"]["bucket"]["name"]
        raw_key = rec["s3"]["object"]["key"]
        key = unquote_plus(raw_key)

        if not _is_original_key(key):
            continue

        parts = key.split("/")
        image_id = parts[1] if len(parts) >= 3 else None

        if not image_id:
            log.warning("Could not parse imageId from key %s", key)
            continue

        head = s3.head_object(Bucket=b, Key=key)
        size_bytes = head["ContentLength"]
        obj = s3.get_object(Bucket=b, Key=key)
        data = obj["Body"].read()
        im = Image.open(io.BytesIO(data))
        width, height = im.size

        ddb.update_item(
            TableName=DDB_META,
            Key={"id": {"S": image_id}},
            UpdateExpression="SET #st = :u, s3_key = :k, #w = :w, #h = :h, bytes = :b",
            ExpressionAttributeNames={"#st":"status","#w":"width","#h":"height"},
            ExpressionAttributeValues={
                ":u":{"S":"UPLOADED"},
                ":k":{"S": key},
                ":w":{"N": str(width)},
                ":h":{"N": str(height)},
                ":b":{"N": str(size_bytes)}
            }
        )

        for sz in DEFAULT_SIZES:
            body = json.dumps({"type":"resize","bucket": b,"key": key,"imageId": image_id,"size": sz})
            sqs.send_message(QueueUrl=RESIZE_Q_URL, MessageBody=body)

        if KINESIS_STREAM_NAME:
            try:
                kin.put_record(StreamName=KINESIS_STREAM_NAME, PartitionKey=image_id, Data=json.dumps({"imageId": image_id, "action":"uploaded"}))
            except Exception as e:
                log.warning("Kinesis put failed: %s", e)

def target_dims(size_name, src_w, src_h):
    targets = {"thumb": 150, "medium": 800, "large": 1600}
    tw = targets.get(size_name, 800)
    scale = tw / float(src_w)

    return int(tw), int(src_h * scale)

def handle_resize_task(task):
    image_id = task["imageId"]
    src_key = task["key"]
    size_name = task["size"]

    obj = s3.get_object(Bucket=BUCKET, Key=src_key)
    data = obj["Body"].read()
    im = Image.open(io.BytesIO(data)).convert("RGB")

    w, h = im.size
    tw, th = target_dims(size_name, w, h)
    im_resized = im.resize((tw, th), Image.LANCZOS)
    out = io.BytesIO()
    im_resized.save(out, format="JPEG", quality=90)
    out.seek(0)

    dest_key = f"images/{image_id}/{size_name}.jpg"

    s3.put_object(Bucket=BUCKET, Key=dest_key, Body=out.getvalue(), ContentType="image/jpeg")
    ddb.update_item(
        TableName=DDB_META,
        Key={"id": {"S": image_id}},
        UpdateExpression="SET #v.#s = :info, #st = :p",
        ExpressionAttributeNames={"#v":"variants","#s":size_name,"#st":"status"},
        ExpressionAttributeValues={
            ":info": {"M": {"key":{"S": dest_key},"width":{"N": str(tw)},"height":{"N": str(th)},"bytes":{"N": str(len(out.getvalue()))}}},
            ":p": {"S": "PROCESSED"}
        }
    )
    log.info("Generated %s for %s", size_name, image_id)

_RUN = True
def _sigterm(*_):
    global _RUN
    _RUN = False
    log.info("Received stop signal; exiting...")

signal.signal(signal.SIGTERM, _sigterm)
signal.signal(signal.SIGINT, _sigterm)

def main_loop():
    log.info("Worker starting; ingest=%s resize=%s", INGEST_Q_URL, RESIZE_Q_URL)

    while _RUN:
        msgs = receive(RESIZE_Q_URL)
        src_queue = RESIZE_Q_URL

        if not msgs:
            msgs = receive(INGEST_Q_URL)
            src_queue = INGEST_Q_URL

        if not msgs:
            continue
        for m in msgs:
            payload = None
            try:
                body = m["Body"]
                payload = json.loads(body)

                if "Records" in payload:
                    handle_s3_ingest(payload)
                elif payload.get("type") == "resize":
                    handle_resize_task(payload)
                else:
                    log.warning("Unknown message: %s", body[:200])
            except Exception as e:
                log.exception("Error handling message: %s", e)
            finally:
                try:
                    delete(src_queue, m["ReceiptHandle"])
                except Exception as e:
                    log.warning("Delete failed: %s", e)

if __name__ == "__main__":
    try:
        main_loop()
    except Exception as e:
        log.exception("Fatal error: %s", e)
        sys.exit(1)
