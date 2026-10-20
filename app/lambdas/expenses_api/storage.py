"""
Receipt storage: every S3 operation lives in this file.
Files are stored at receipts/<userId>/<expenseId>.
The SERVER always builds this path; users never choose it.
"""
import os

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

BUCKET = os.environ["RECEIPTS_BUCKET"]

UPLOAD_LINK_SECONDS = 300    # upload forms are valid for 5 minutes
DOWNLOAD_LINK_SECONDS = 300  # download links are valid for 5 minutes
MAX_RECEIPT_BYTES = 5 * 1024 * 1024  # 5 MB
ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png", "application/pdf"}

# Signature version 4 is required for presigned URLs on modern buckets.
# "virtual" addressing produces URLs like https://<bucket>.s3.amazonaws.com/...
_s3 = boto3.client(
    "s3",
    config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
)


def _key(user_id, expense_id):
    return f"receipts/{user_id}/{expense_id}"


def create_upload_form(user_id, expense_id, content_type):
    """
    A presigned POST: a URL plus form fields. S3 enforces the conditions:
    exact location, exact content type, size between 1 byte and 5 MB.
    """
    return _s3.generate_presigned_post(
        Bucket=BUCKET,
        Key=_key(user_id, expense_id),
        Fields={"Content-Type": content_type},
        Conditions=[
            {"Content-Type": content_type},
            ["content-length-range", 1, MAX_RECEIPT_BYTES],
        ],
        ExpiresIn=UPLOAD_LINK_SECONDS,
    )


def create_download_link(user_id, expense_id):
    """A presigned GET URL that works for 5 minutes."""
    return _s3.generate_presigned_url(
        "get_object",
        Params={
            "Bucket": BUCKET,
            "Key": _key(user_id, expense_id),
            "ResponseContentDisposition": "inline",  # show in the browser
        },
        ExpiresIn=DOWNLOAD_LINK_SECONDS,
    )


def receipt_exists(user_id, expense_id):
    try:
        _s3.head_object(Bucket=BUCKET, Key=_key(user_id, expense_id))
        return True
    except ClientError as error:
        if error.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
            return False
        raise


def delete_receipt(user_id, expense_id):
    # Deleting a missing object is not an error in S3, so this is safe to
    # call whether or not a receipt was ever uploaded. With versioning on,
    # the file is recoverable for 30 days (see the lifecycle rule).
    _s3.delete_object(Bucket=BUCKET, Key=_key(user_id, expense_id))