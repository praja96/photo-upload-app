import os, json, uuid, boto3, base64

s3 = boto3.client("s3")
BUCKET = os.environ["BUCKET_NAME"]
MAX_BYTES = int(os.environ.get("MAX_UPLOAD_BYTES", str(50*1024*1024)))

def handler(event, context):
    try:
        req = json.loads(event.get("body") or "{}")
        filename     = req.get("filename") or "upload.bin"
        content_type = req.get("contentType") or "application/octet-stream"

        # Optional: enforce simple allowlist by MIME
        # if not content_type.startswith(("image/", "application/pdf")):
        #     return _bad_request("Unsupported contentType")

        key = f"uploads/{uuid.uuid4()}/{filename}"

        conditions = [
            {"bucket": BUCKET},
            ["content-length-range", 1, MAX_BYTES],
            {"key": key},
            {"Content-Type": content_type}
        ]

        # Optional: set server-side encryption
        fields = {
            "Content-Type": content_type,
            "x-amz-server-side-encryption": "AES256"
        }
        conditions.append({"x-amz-server-side-encryption": "AES256"})

        presigned = s3.generate_presigned_post(
            Bucket=BUCKET,
            Key=key,
            Fields=fields,
            Conditions=conditions,
            ExpiresIn=300  # 5 minutes
        )

        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json"
            },
            "body": json.dumps({
                "url": presigned["url"],
                "fields": presigned["fields"],
                "key": key,
                "bucket": BUCKET,
                "maxBytes": MAX_BYTES
            })
        }
    except Exception as e:
        return _error(str(e))

def _bad_request(msg):
    return {"statusCode": 400, "headers": {"Content-Type": "application/json"}, "body": json.dumps({"error": msg})}

def _error(msg):
    print("Error:", msg)
    return {"statusCode": 500, "headers": {"Content-Type": "application/json"}, "body": json.dumps({"error": "Internal error"})}
