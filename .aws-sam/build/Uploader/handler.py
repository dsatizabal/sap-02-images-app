import os, json, uuid, time
import boto3
import urllib.request

_CONFIG = None
_S3 = None
_DDB = None
_KIN = None

# ---------------- AppConfig (Lambda Extension) ----------------
def load_appconfig_extension():
    """Load JSON via AWS AppConfig Lambda Extension.
    Requires:
      - AppConfig Lambda Extension layer on the function
      - Env: APPCONFIG_APPLICATION, APPCONFIG_ENVIRONMENT, APPCONFIG_PROFILE
      - IAM: appconfig:StartConfigurationSession, appconfig:GetLatestConfiguration (etc.)
    """
    app = os.getenv("APPCONFIG_APPLICATION")
    env = os.getenv("APPCONFIG_ENVIRONMENT")
    profile = os.getenv("APPCONFIG_PROFILE")

    if not (app and env and profile):
        return {}

    url = f"http://localhost:2772/applications/{app}/environments/{env}/configurations/{profile}"

    try:
        with urllib.request.urlopen(url, timeout=1.5) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:
        print("Error getting AppConfig parameters: ", e)
        return {}

# ---------------- Optional: Parameter Store by path ----------------
def load_ssm_config():
    path = os.getenv("SSM_PARAM_PATH", "").strip()
    region = os.getenv("SSM_REGION", os.getenv("REGION", "us-east-1"))

    if not path:
        return {}

    ssm = boto3.client("ssm", region_name=region)
    params = {}
    next_token = None

    while True:
        kwargs = dict(Path=path, WithDecryption=True, Recursive=True)
        if next_token:
            kwargs["NextToken"] = next_token

        resp = ssm.get_parameters_by_path(**kwargs)

        for p in resp.get("Parameters", []):
            name = p["Name"].split("/")[-1]
            params[name] = p["Value"]
        next_token = resp.get("NextToken")

        if not next_token:
            break

    mapped = {
        "BUCKET_NAME": params.get("bucket_name"),
        "DDB_TABLE_METADATA": params.get("ddb_table_metadata"),
        "KINESIS_STREAM_NAME": params.get("kinesis_stream_name", ""),
        "REGION": params.get("region", os.getenv("REGION", "us-east-1")),
    }
    mapped["URL_EXPIRY_SECONDS"] = int(params.get("url_expiry_seconds", os.getenv("URL_EXPIRY_SECONDS", "900")))
    mapped["MAX_SIZE_MB"] = int(params.get("max_size_mb", os.getenv("MAX_SIZE_MB", "25")))
    default_sizes = params.get("default_sizes", os.getenv("DEFAULT_SIZES", "thumb,medium,large"))
    mapped["DEFAULT_SIZES"] = [s.strip() for s in default_sizes.split(",") if s.strip()]

    return mapped

def normalize(cfg):
    """Accept snake_case or UPPER_CASE keys and apply env overrides."""

    def to_int(x, d):
        try: return int(x)
        except Exception: return d

    out = {}
    out["BUCKET_NAME"] = cfg.get("bucket_name") or cfg.get("BUCKET_NAME")
    out["DDB_TABLE_METADATA"] = cfg.get("ddb_table_metadata") or cfg.get("DDB_TABLE_METADATA")
    out["KINESIS_STREAM_NAME"] = cfg.get("kinesis_stream_name") or cfg.get("KINESIS_STREAM_NAME", "")
    out["REGION"] = cfg.get("region") or cfg.get("REGION") or os.getenv("REGION", "us-east-1")

    sizes = cfg.get("default_sizes") or cfg.get("DEFAULT_SIZES") or "thumb,medium,large"

    if isinstance(sizes, str):
        sizes = [s.strip() for s in sizes.split(",") if s.strip()]

    out["DEFAULT_SIZES"] = sizes if isinstance(sizes, list) else ["thumb","medium","large"]
    out["URL_EXPIRY_SECONDS"] = to_int(cfg.get("url_expiry_seconds") or cfg.get("URL_EXPIRY_SECONDS") or 900, 900)
    out["MAX_SIZE_MB"] = to_int(cfg.get("max_size_mb") or cfg.get("MAX_SIZE_MB") or 25, 25)

    # Env overrides always win
    env_overrides = {
        "BUCKET_NAME": os.getenv("BUCKET_NAME"),
        "DDB_TABLE_METADATA": os.getenv("DDB_TABLE_METADATA"),
        "KINESIS_STREAM_NAME": os.getenv("KINESIS_STREAM_NAME"),
        "REGION": os.getenv("REGION"),
        "URL_EXPIRY_SECONDS": os.getenv("URL_EXPIRY_SECONDS"),
        "MAX_SIZE_MB": os.getenv("MAX_SIZE_MB"),
        "DEFAULT_SIZES": os.getenv("DEFAULT_SIZES"),
    }

    if env_overrides["DEFAULT_SIZES"]:
        env_overrides["DEFAULT_SIZES"] = [s.strip() for s in env_overrides["DEFAULT_SIZES"].split(",") if s.strip()]

    for k, v in env_overrides.items():
        if v not in (None, ""):
            out[k] = v

    missing = [k for k in ("BUCKET_NAME","DDB_TABLE_METADATA") if not out.get(k)]

    if missing:
        raise RuntimeError(f"Missing required config: {missing}. Provide via AppConfig (preferred) or environment variables.")

    return out

def load_config():
    # Order: AppConfig(Extension) -> SSM by path (optional) -> ENV defaults
    cfg = {}
    appcfg = load_appconfig_extension()

    print("AppConfig JSON: ", appcfg)

    if appcfg:
        cfg.update(appcfg)

    if not cfg:
        ssm_cfg = load_ssm_config()
        if ssm_cfg:
            cfg.update(ssm_cfg)

    return normalize(cfg)

def clients(region):
    s3 = boto3.client("s3", region_name=region)
    ddb = boto3.client("dynamodb", region_name=region)
    kin = boto3.client("kinesis", region_name=region)

    return s3, ddb, kin

def lambda_handler(event, context):
    global _CONFIG, _S3, _DDB, _KIN

    if _CONFIG is None:
        _CONFIG = load_config()
        _S3, _DDB, _KIN = clients(_CONFIG["REGION"])

    BUCKET = _CONFIG["BUCKET_NAME"]
    TABLE  = _CONFIG["DDB_TABLE_METADATA"]
    STREAM = _CONFIG.get("KINESIS_STREAM_NAME", "")
    URL_EXPIRY = int(_CONFIG["URL_EXPIRY_SECONDS"])
    MAX_SIZE_MB = int(_CONFIG["MAX_SIZE_MB"])
    DEFAULT_SIZES = _CONFIG["DEFAULT_SIZES"]

    # optional client sizes override
    try:
        body = event.get("body")
        if body and isinstance(body, str):
            body = json.loads(body)
        elif body is None:
            body = {}

    except Exception:
        body = {}

    override_sizes = body.get("sizes") if isinstance(body, dict) else None

    if isinstance(override_sizes, list) and 0 < len(override_sizes) <= 10:
        candidate = [str(s).strip() for s in override_sizes if s.strip()]
        if candidate:
            DEFAULT_SIZES = candidate

    image_id = uuid.uuid4().hex[:26]
    key = f"images/{image_id}/original.jpg"

    conditions = [
        ["content-length-range", 1, MAX_SIZE_MB * 1024 * 1024],
        {"key": key}
    ]

    fields = {"key": key}

    presigned = _S3.generate_presigned_post(
        Bucket=BUCKET,
        Key=key,
        Fields=fields,
        Conditions=conditions,
        ExpiresIn=URL_EXPIRY
    )

    now = int(time.time())
    
    _DDB.put_item(
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
            _KIN.put_record(StreamName=STREAM, PartitionKey=image_id,
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
