"""
Uploads a receipt exactly the way the browser will:
  1. ask our API for a presigned upload form
  2. POST the file straight to S3 using that form

Usage:  python3 scripts/upload_receipt.py <api_url> <expense_id> <file>
The access token is read from the TOKEN environment variable.
Uses only Python's standard library, so nothing needs installing.
"""
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request
import uuid


def request_upload_form(api_url, token, expense_id, content_type):
    request = urllib.request.Request(
        f"{api_url}/expenses/{expense_id}/receipt",
        method="POST",
        data=json.dumps({"contentType": content_type}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)["upload"]


def build_multipart_form(fields, file_name, content_type, file_bytes):
    """Builds the same kind of form body a browser sends. The file goes LAST."""
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        )
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{file_name}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n".encode()
    )
    parts.append(file_bytes)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def main():
    api_url, expense_id, path = sys.argv[1:4]
    token = os.environ["TOKEN"]
    content_type = mimetypes.guess_type(path)[0] or "application/octet-stream"

    try:
        upload = request_upload_form(api_url, token, expense_id, content_type)
        print("Got a presigned upload form from the API")

        with open(path, "rb") as file:
            body, form_type = build_multipart_form(
                upload["fields"], os.path.basename(path), content_type, file.read()
            )

        s3_request = urllib.request.Request(
            upload["url"], data=body, method="POST", headers={"Content-Type": form_type}
        )
        with urllib.request.urlopen(s3_request) as response:
            print(f"Uploaded to S3: HTTP {response.status}")
    except urllib.error.HTTPError as error:
        print(f"Rejected: HTTP {error.code}")
        print(error.read().decode()[:600])
        sys.exit(1)


if __name__ == "__main__":
    main()