import os, json, time, logging, io, signal, sys, urllib.request
from urllib.parse import unquote_plus
import boto3
from PIL import Image

# -------- Logging / tunables --------
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=getattr(logging, LOG_LEVEL, logging.INFO),
                    format="%(asctime)s %(levelname)s %(name)s :: %(message)s")
log = logging.getLogger("worker")

POLL_WAIT_SECONDS   = int(os.getenv("POLL_WAIT_SECONDS", "20"))
VISIBILITY_TIMEOUT  = int(os.getenv("VISIBILITY_TIMEOUT", "60"))
HEARTBEAT_EVERY     = int(os.getenv("HEARTBEAT_EVERY", "30"))          # loops
QUEUE_STATS_EVERY   = int(os.getenv("QUEUE_STATS_EVERY", "60"))        # loops

APPCONFIG_RETRIES     = int(os.getenv("APPCONFIG_RETRIES", "0"))       # 0 = no retry (compose wait loop usually handles it)
APPCONFIG_RETRY_SLEEP = float(os.getenv("APPCONFIG_RETRY_SLEEP", "1"))

# -------- AppConfig (Lambda extension/Agent endpoint) --------
def _load_appconfig_extension():
    app = os.getenv("APPCONFIG_APPLICATION")
    env = os.getenv("APPCONFIG_ENVIRONMENT")
    profile = os.getenv("APPCONFIG_PROFILE")
    if not (app and env and profile):
        log.info("APPCONFIG_* not set; skipping AppConfig and using ENV only.")
        return {}

    base = os.getenv("APPCONFIG_BASE_URL", "http://localhost:2772")
    url  = f"{base}/applications/{app}/environments/{env}/configurations/{profile}"
    attempts = max(1, APPCONFIG_RETRIES or 1)

    for i in range(1, attempts + 1):
        try:
            log.info("Loading config from AppConfig: %s (try %d/%d)", url, i, attempts)
            with urllib.request.urlopen(url, timeout=2.5) as r:
                txt = r.read().decode("utf-8")
                cfg = json.loads(txt)
                log.info("AppConfig loaded with keys: %s", sorted(cfg.keys()))
                return cfg
        except Exception as e:
            if i == attempts:
                log.warning("AppConfig not reachable after %d attempts: %s; falling back to ENV", attempts, e)
                break
            time.sleep(APPCONFIG_RETRY_SLEEP)

    return {}

def _normalize(cfg):
    def val(*keys, default=None):
        for k in keys:
            if k in cfg and cfg[k] not in (None, ""):
                return cfg[k]
        return default

    region         = val("region", "REGION", default=os.getenv("REGION", "us-east-1"))
    bucket         = val("bucket_name", "BUCKET_NAME", default=os.getenv("BUCKET_NAME"))
    ddb_meta       = val("ddb_table_metadata", "DDB_TABLE_METADATA", default=os.getenv("DDB_TABLE_METADATA"))
    ddb_counters   = val("ddb_table_counters", "DDB_TABLE_COUNTERS", default=os.getenv("DDB_TABLE_COUNTERS", ""))
    ingest_q       = val("ingest_queue_url", "INGEST_QUEUE_URL", default=os.getenv("INGEST_QUEUE_URL"))
    resize_q       = val("resize_queue_url", "RESIZE_QUEUE_URL", default=os.getenv("RESIZE_QUEUE_URL"))
    kinesis_stream = val("kinesis_stream_name", "KINESIS_STREAM_NAME", default=os.getenv("KINESIS_STREAM_NAME", ""))
    default_sizes  = val("default_sizes", "DEFAULT_SIZES", default=os.getenv("DEFAULT_SIZES", "thumb,medium,large"))

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

    # ENV overrides on top of AppConfig
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

    norm = _normalize(cfg)
    # Small redacted config log
    redacted = dict(norm)
    for k in ("INGEST_QUEUE_URL", "RESIZE_QUEUE_URL"):
        if redacted.get(k):
            redacted[k] = redacted[k].rsplit("/", 1)[-1]
    log.info("Effective config: %s", redacted)
    return norm

# -------- Load config & clients --------
_CFG = load_config()
REGION = _CFG["REGION"]
BUCKET = _CFG["BUCKET_NAME"]
DDB_META = _CFG["DDB_TABLE_METADATA"]
DDB_COUNTERS = _CFG["DDB_TABLE_COUNTERS"]
INGEST_Q_URL = _CFG["INGEST_QUEUE_URL"]
RESIZE_Q_URL = _CFG["RESIZE_QUEUE_URL"]
KINESIS_STREAM_NAME = _CFG["KINESIS_STREAM_NAME"]
DEFAULT_SIZES = _CFG["DEFAULT_SIZES"]

sqs = boto3.client("sqs", region_name=REGION)
s3  = boto3.client("s3",  region_name=REGION)
ddb = boto3.client("dynamodb", region_name=REGION)
kin = boto3.client("kinesis",  region_name=REGION)

# -------- Helpers --------
def receive(queue_url):
    qname = queue_url.rsplit("/", 1)[-1]
    log.debug("Polling SQS '%s' (wait=%ss, vis=%ss)", qname, POLL_WAIT_SECONDS, VISIBILITY_TIMEOUT)
    try:
        resp = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=5,
            WaitTimeSeconds=POLL_WAIT_SECONDS,
            VisibilityTimeout=VISIBILITY_TIMEOUT
        )
        msgs = resp.get("Messages", [])
        if msgs:
            log.info("Received %d message(s) from '%s'", len(msgs), qname)
        else:
            log.debug("No messages from '%s'", qname)
        return msgs
    except Exception as e:
        log.exception("SQS receive_message failed for '%s': %s", qname, e)
        return []

def delete(queue_url, receipt):
    qname = queue_url.rsplit("/", 1)[-1]
    try:
        sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt)
        log.debug("Deleted message from '%s'", qname)
    except Exception as e:
        log.warning("Delete failed for '%s': %s", qname, e)

def _is_original_key(key: str) -> bool:
    last = key.rsplit('/', 1)[-1]
    return last.startswith("original")

# -------- Handlers --------
def handle_s3_ingest(evt):
    log.info("Handling S3 ingest event with %d record(s)", len(evt.get("Records", [])))
    for rec in evt["Records"]:
        try:
            b = rec["s3"]["bucket"]["name"]
            raw_key = rec["s3"]["object"]["key"]
            key = unquote_plus(raw_key)
            log.info("S3 event: bucket=%s key=%s", b, key)

            if not _is_original_key(key):
                log.info("Skipping key (not original.*): %s", key)
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
            log.info("Original stats id=%s bytes=%s WxH=%sx%s", image_id, size_bytes, width, height)

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
            log.info("DDB updated for %s -> status=UPLOADED", image_id)

            for sz in DEFAULT_SIZES:
                body = json.dumps({"type":"resize","bucket": b,"key": key,"imageId": image_id,"size": sz})
                resp = sqs.send_message(QueueUrl=RESIZE_Q_URL, MessageBody=body)
                log.info("Enqueued resize task %s for %s (MessageId=%s)", sz, image_id, resp.get("MessageId"))

            if KINESIS_STREAM_NAME:
                try:
                    kin.put_record(StreamName=KINESIS_STREAM_NAME, PartitionKey=image_id,
                                   Data=json.dumps({"imageId": image_id, "action":"uploaded"}))
                    log.info("Kinesis signaled 'uploaded' for %s", image_id)
                except Exception as e:
                    log.warning("Kinesis put failed for %s: %s", image_id, e)
        except Exception as e:
            log.exception("Error handling S3 record: %s", e)

def target_dims(size_name, src_w, src_h):
    targets = {"thumb": 150, "medium": 800, "large": 1600}
    tw = targets.get(size_name, 800)
    scale = max(1e-9, tw / float(src_w))
    return int(tw), int(round(src_h * scale))

def handle_resize_task(task):
    image_id = task["imageId"]; src_key = task["key"]; size_name = task["size"]
    log.info("Resizing %s -> %s", image_id, size_name)
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
    log.info("Generated %s for %s -> %s", size_name, image_id, dest_key)

# -------- Main loop --------
_RUN = True
def _sigterm(*_):
    global _RUN
    _RUN = False
    log.info("Received stop signal; exiting...")

signal.signal(signal.SIGTERM, _sigterm)
signal.signal(signal.SIGINT, _sigterm)

def _queue_stats_every(loop_idx):
    if QUEUE_STATS_EVERY and loop_idx % QUEUE_STATS_EVERY == 0:
        try:
            for name, qurl in (("ingest", INGEST_Q_URL), ("resize", RESIZE_Q_URL)):
                attrs = sqs.get_queue_attributes(
                    QueueUrl=qurl,
                    AttributeNames=["ApproximateNumberOfMessages","ApproximateNumberOfMessagesNotVisible"]
                ).get("Attributes", {})
                log.info("QStats %-6s: visible=%s inflight=%s",
                         name, attrs.get("ApproximateNumberOfMessages"), attrs.get("ApproximateNumberOfMessagesNotVisible"))
        except Exception as e:
            log.debug("QStats fetch failed: %s", e)

def main_loop():
    log.info("Worker starting; ingest=%s resize=%s wait=%ss vis=%ss",
             INGEST_Q_URL.rsplit('/',1)[-1], RESIZE_Q_URL.rsplit('/',1)[-1],
             POLL_WAIT_SECONDS, VISIBILITY_TIMEOUT)
    loop = 0
    while _RUN:
        loop += 1
        msgs = receive(RESIZE_Q_URL)
        src_queue = RESIZE_Q_URL

        if not msgs:
            msgs = receive(INGEST_Q_URL)
            src_queue = INGEST_Q_URL

        if not msgs:
            if HEARTBEAT_EVERY and loop % HEARTBEAT_EVERY == 0:
                log.info("Heartbeat: idle (loop=%d)", loop)
            _queue_stats_every(loop)
            continue

        for m in msgs:
            payload = None
            try:
                body = m.get("Body", "")
                payload = json.loads(body)
                if "Records" in payload:
                    handle_s3_ingest(payload)
                elif payload.get("type") == "resize":
                    handle_resize_task(payload)
                else:
                    log.warning("Unknown message shape (first 200 chars): %s", body[:200])
            except Exception as e:
                log.exception("Error handling message: %s", e)
            finally:
                delete(src_queue, m["ReceiptHandle"])

if __name__ == "__main__":
    try:
        main_loop()
    except Exception as e:
        log.exception("Fatal error: %s", e)
        sys.exit(1)
