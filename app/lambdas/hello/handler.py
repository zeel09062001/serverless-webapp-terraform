import json
from datetime import datetime, timezone

def response(status_code, body):
    """Build a response in the format API Gateway expects."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    """Entry point: Lambda calls this for every request."""
    path = event.get("rawPath", "")

    if path == "/hello":
        return response(200, {"message": "Hello from your serverless app!"})

    if path == "/time":
        now = datetime.now(timezone.utc).isoformat()
        return response(200, {"time": now})

    return response(404, {"error": f"Route {path} not found"})
