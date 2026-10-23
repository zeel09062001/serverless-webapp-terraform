"""Small helpers that build the events AWS would send our Lambdas."""
import json


class FakeContext:
    """Lambda passes a 'context' object; our code only uses the request ID."""
    aws_request_id = "test-request-id"


VALID_EXPENSE = {
    "amountCents": 1250,
    "category": "food",
    "merchant": "Corner Cafe",
    "date": "2026-10-05",
}


def api_event(route_key, user_id="user-a", expense_id=None, body=None, query=None):
    """Mimics what API Gateway sends after the JWT authorizer has verified a token."""
    event = {"routeKey": route_key, "headers": {}, "requestContext": {}}
    if user_id is not None:
        event["requestContext"] = {"authorizer": {"jwt": {"claims": {"sub": user_id}}}}
    if expense_id is not None:
        event["pathParameters"] = {"id": expense_id}
    if body is not None:
        event["body"] = body if isinstance(body, str) else json.dumps(body)
    if query is not None:
        event["queryStringParameters"] = query
    return event


def call(handler_module, event):
    """Runs the Lambda and returns (status code, parsed JSON body or None)."""
    response = handler_module.handler(event, FakeContext())
    body = response.get("body")
    return response["statusCode"], (json.loads(body) if body else None)


def s3_message(key, size=100, message_id="msg-1"):
    """An SQS message containing an S3 'object created' event."""
    s3_event = {
        "Records": [
            {
                "eventName": "ObjectCreated:Post",
                "s3": {
                    "bucket": {"name": "test-receipts"},
                    "object": {"key": key, "size": size},
                },
            }
        ]
    }
    return {"messageId": message_id, "body": json.dumps(s3_event)}