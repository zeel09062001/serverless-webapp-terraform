"""
Receipt worker: runs in the background for every uploaded receipt.
S3 notifies an SQS queue, and Lambda calls this function with batches
of messages. For each uploaded file it:
  1. reads the first 8 bytes to find the file's REAL format
  2. if it's a genuine JPEG/PNG/PDF matching its declared type:
       marks the expense ATTACHED
     otherwise:
       deletes the file and marks the expense REJECTED
Messages that raise an exception are retried, then go to the DLQ.
"""
import json
import logging
import os
import uuid
from datetime import datetime, timezone
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET = os.environ["RECEIPTS_BUCKET"]
_s3 = boto3.client("s3")
_table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])

# "Magic numbers": the first bytes of a file reveal its real format,
# whatever its name or declared type claims.
SIGNATURES = {
    b"\xff\xd8\xff": "image/jpeg",
    b"\x89PNG\r\n\x1a\n": "image/png",
    b"%PDF-": "application/pdf",
}


def log(message, **details):
    logger.info(json.dumps({"message": message, **details}))


def detect_type(first_bytes):
    for signature, content_type in SIGNATURES.items():
        if first_bytes.startswith(signature):
            return content_type
    return None


def parse_key(key):
    """receipts/<userId>/<expenseId> -> (userId, expenseId), or None if malformed."""
    parts = key.split("/")
    if len(parts) != 3 or parts[0] != "receipts" or not parts[1]:
        return None
    try:
        return parts[1], str(uuid.UUID(parts[2]))
    except ValueError:
        return None


def read_first_bytes(key):
    """(first 8 bytes, declared type), or None if the file no longer exists."""
    try:
        obj = _s3.get_object(Bucket=BUCKET, Key=key, Range="bytes=0-7")
    except ClientError as error:
        if error.response["Error"]["Code"] in ("NoSuchKey", "404"):
            return None
        raise
    return obj["Body"].read(), obj.get("ContentType", "")


def set_receipt_status(user_id, expense_id, status, extra_fields=None):
    """Update the expense's receipt fields. False if the expense no longer exists."""
    fields = {
        "receiptStatus": status,
        "receiptCheckedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        **(extra_fields or {}),
    }
    try:
        _table.update_item(
            # Same key format as the API's repository.py
            Key={"PK": f"USER#{user_id}", "SK": f"EXPENSE#{expense_id}"},
            UpdateExpression="SET " + ", ".join(f"#{name} = :{name}" for name in fields),
            ConditionExpression="attribute_exists(PK)",
            ExpressionAttributeNames={f"#{name}": name for name in fields},
            ExpressionAttributeValues={f":{name}": value for name, value in fields.items()},
        )
        return True
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def process_receipt(key, size):
    ids = parse_key(key)
    if ids is None:
        log("Ignoring object with unexpected key", key=key)
        return
    user_id, expense_id = ids

    result = read_first_bytes(key)
    if result is None:
        log("File already gone, nothing to do", key=key)
        return
    first_bytes, declared_type = result
    actual_type = detect_type(first_bytes)

    if actual_type is not None and actual_type == declared_type:
        attached = set_receipt_status(
            user_id, expense_id, "ATTACHED",
            {"receiptContentType": actual_type, "receiptSizeBytes": size},
        )
        if attached:
            log("Receipt accepted", key=key, type=actual_type, size=size)
        else:
            # The expense was deleted while the file was uploading
            _s3.delete_object(Bucket=BUCKET, Key=key)
            log("Expense no longer exists, removed orphaned file", key=key)
        return

    _s3.delete_object(Bucket=BUCKET, Key=key)
    set_receipt_status(user_id, expense_id, "REJECTED")
    log("Receipt rejected", key=key, declaredType=declared_type, actualType=actual_type)


def handle_message(message):
    # A body that isn't valid JSON raises here -> retried -> DLQ.
    # That's deliberate: a message we can't understand needs a human.
    body = json.loads(message["body"])

    # S3 sends this once when the notification is first set up
    if body.get("Event") == "s3:TestEvent":
        log("Ignoring S3 test event")
        return

    for record in body["Records"]:
        # Keys arrive URL-encoded (a space becomes "+"), so decode them
        key = unquote_plus(record["s3"]["object"]["key"])
        size = record["s3"]["object"].get("size", 0)
        process_receipt(key, size)


def handler(event, context):
    failures = []
    for message in event["Records"]:
        try:
            handle_message(message)
        except Exception:
            logger.exception("Failed to process message %s", message["messageId"])
            failures.append({"itemIdentifier": message["messageId"]})

    # Only the failed messages are retried; the rest are deleted from the queue
    return {"batchItemFailures": failures}