import os, json, uuid, boto3
from botocore.exceptions import ClientError, EndpointConnectionError

# ============ Env ============
ALLOWED_BUCKETS      = [b.strip() for b in os.environ.get("ALLOWED_BUCKETS","").split(",") if b.strip()]
BUCKET_TAG_KEY       = os.environ.get("BUCKET_TAG_KEY")         # e.g., "Uploader"
BUCKET_TAG_VALUE     = os.environ.get("BUCKET_TAG_VALUE")       # e.g., "enabled"
BUCKET_NAME_PREFIX   = os.environ.get("BUCKET_NAME_PREFIX","")  # e.g., "rajas-"
MAX_UPLOAD_BYTES     = int(os.environ.get("MAX_UPLOAD_BYTES", str(200*1024*1024)))  # 200MB
ENFORCE_USER_PREFIX  = os.environ.get("ENFORCE_USER_PREFIX","false").lower()=="true"
ALLOWED_ORIGIN       = os.environ.get("ALLOWED_ORIGIN","*")
DEBUG                = os.environ.get("DEBUG","false").lower()=="true"

# ============ Helpers ============
def _cors_headers(origin="*"):
    return {
        "Access-Control-Allow-Origin": origin,
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    }

def _resp(status, payload, origin="*"):
    return {"statusCode": status,
            "headers": {**_cors_headers(origin), "Content-Type": "application/json"},
            "body": json.dumps(payload)}

def _bad(status, msg, origin="*"):
    return _resp(status, {"error": msg}, origin)

def _get_origin(event):
    h = event.get("headers") or {}
    return h.get("origin") or h.get("Origin") or ALLOWED_ORIGIN

def _sanitize_folder(folder: str) -> str:
    if not folder: return ""
    folder = folder.replace("\\","/").strip().lstrip("/").rstrip("/")
    parts = [p for p in folder.split("/") if p and p not in (".","..")]
    return "/".join(parts)

def _bucket_region(s3_global, bucket: str) -> str:
    loc = s3_global.get_bucket_location(Bucket=bucket).get("LocationConstraint")
    return loc or "us-east-1"

def _bucket_encryption(s3_regional, bucket: str):
    try:
        enc = s3_regional.get_bucket_encryption(Bucket=bucket)
        rule = enc["ServerSideEncryptionConfiguration"]["Rules"][0]["ApplyServerSideEncryptionByDefault"]
        algo = rule["SSEAlgorithm"]              # 'AES256' or 'aws:kms'
        key_arn = rule.get("KMSMasterKeyID")
        return algo, key_arn
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("ServerSideEncryptionConfigurationNotFoundError","NoSuchEncryptionConfiguration"):
            return "AES256", None
        raise

def _list_allowed_buckets_safe():
    """
    Try to list buckets and filter by name/tag/allow-list.
    If listing fails (IAM/VPC), fall back to ALLOWED_BUCKETS.
    Returns (names, mode, errstr_or_None)
    """
    try:
        s3 = boto3.client("s3")
        resp = s3.list_buckets()  # needs s3:ListAllMyBuckets
        names = [b["Name"] for b in resp.get("Buckets", [])]

        if BUCKET_NAME_PREFIX:
            names = [n for n in names if n.startswith(BUCKET_NAME_PREFIX)]

        if BUCKET_TAG_KEY:
            filtered = []
            for n in names:
                try:
                    t = s3.get_bucket_tagging(Bucket=n)  # may need s3:GetBucketTagging
                    tags = {d["Key"]: d["Value"] for d in t.get("TagSet", [])}
                    ok = (BUCKET_TAG_VALUE is None and BUCKET_TAG_KEY in tags) or (tags.get(BUCKET_TAG_KEY) == BUCKET_TAG_VALUE)
                    if ok: filtered.append(n)
                except ClientError as e:
                    code = e.response["Error"]["Code"]
                    if code in ("NoSuchTagSet","NoSuchTagSetError","AccessDenied"):
                        continue  # skip buckets we can't tag-read
                    raise
            names = filtered

        if ALLOWED_BUCKETS:
            names = [n for n in names if n in ALLOWED_BUCKETS]

        return names, "listed", None

    except (ClientError, EndpointConnectionError, Exception) as e:
        # Fall back to allow-list if provided
        err = f"{type(e).__name__}: {getattr(e,'response',getattr(e,'args',[''])[0])}"
        print("ERROR list_buckets:", err)
        if ALLOWED_BUCKETS:
            return ALLOWED_BUCKETS, "fallback-allowed-buckets", err
        # last resort: return empty list but do NOT 500
        return [], "fallback-empty", err

# ============ Handler ============
def handler(event, context):
    origin = _get_origin(event)
    http = event.get("requestContext", {}).get("http", {})
    method = http.get("method","")
    path = event.get("rawPath") or http.get("path") or event.get("path","")

    # CORS preflight
    if method == "OPTIONS":
        return {"statusCode": 204, "headers": _cors_headers(origin), "body": ""}

    # Health (optional)
    if method == "GET" and path.endswith("/health"):
        return _resp(200, {"ok": True}, origin)

    # ---- GET /buckets ----
    if method == "GET" and path.endswith("/buckets"):
        names, mode, err = _list_allowed_buckets_safe()
        payload = {"buckets": names, "mode": mode}
        if DEBUG and err: payload["debug"] = err
        return _resp(200, payload, origin)

    # ---- POST /presign ----
    if method == "POST" and path.endswith("/presign"):
        try:
            body = json.loads(event.get("body") or "{}")
            filename = body.get("filename") or "upload.bin"
            bucket   = body.get("bucket")
            folder   = _sanitize_folder(body.get("folder") or "")

            if not bucket:
                return _bad(400, "Missing 'bucket'", origin)
            if ALLOWED_BUCKETS and bucket not in ALLOWED_BUCKETS:
                return _bad(403, f"Bucket '{bucket}' not allowed", origin)

            claims  = (event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {}))
            user_id = claims.get("sub", "anon")

            prefix = f"{folder}/" if folder else ""
            if ENFORCE_USER_PREFIX:
                prefix = f"uploads/{user_id}/" + prefix

            key = f"{prefix}{filename}"

            s3_global = boto3.client("s3")
            region    = _bucket_region(s3_global, bucket)
            s3        = boto3.client("s3", region_name=region)

            algo, bucket_kms = _bucket_encryption(s3, bucket)

            fields = {}
            conditions = [
                {"bucket": bucket},
                {"key": key},
                ["content-length-range", 1, MAX_UPLOAD_BYTES],
            ]
            if algo == "aws:kms":
                fields["x-amz-server-side-encryption"] = "aws:kms"
                conditions.append({"x-amz-server-side-encryption": "aws:kms"})
                if bucket_kms:
                    fields["x-amz-server-side-encryption-aws-kms-key-id"] = bucket_kms
                    conditions.append({"x-amz-server-side-encryption-aws-kms-key-id": bucket_kms})
            else:
                fields["x-amz-server-side-encryption"] = "AES256"
                conditions.append({"x-amz-server-side-encryption": "AES256"})

            presigned = s3.generate_presigned_post(
                Bucket=bucket,
                Key=key,
                Fields=fields,
                Conditions=conditions,
                ExpiresIn=300,
            )
            presigned["url"] = f"https://{bucket}.s3.{region}.amazonaws.com"

            return _resp(200, {
                "url":    presigned["url"],
                "fields": presigned["fields"],
                "key":    key,
                "bucket": bucket,
                "region": region,
                "sse":    algo
            }, origin)

        except Exception as e:
            err = f"{type(e).__name__}: {getattr(e,'response',getattr(e,'args',[''])[0])}"
            print("ERROR presign:", err)
            payload = {"error": "Internal error"}
            if DEBUG: payload["debug"] = err
            return _resp(500, payload, origin)

    # ---- Not found ----
    return _bad(404, "Not found", origin)
