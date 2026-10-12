import json


def handler(event, context):
    """Simplest possible Lambda: returns a JSON greeting."""
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": "Hello from your serverless app!"}),
    }
