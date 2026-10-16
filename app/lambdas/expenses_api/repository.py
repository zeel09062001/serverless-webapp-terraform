"""
Data access layer: every DynamoDB call lives in this file.
The rest of the code never builds keys or talks to DynamoDB directly.
"""
import os
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

# Created ONCE when the Lambda container starts (outside any function),
# then reused by every request this container handles. Faster than
# reconnecting on every request.
# os.environ["TABLE_NAME"] fails immediately if the variable is missing,
# which is what we want: fail fast with a clear error.
_table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])

# Fields a user may leave out. On update, a missing optional field is removed.
OPTIONAL_FIELDS = ("note",)

# Attributes used only for DynamoDB organisation, never shown to users.
_KEY_ATTRIBUTES = ("PK", "SK", "GSI1PK", "GSI1SK")


# ---------------------------------------------------------------------------
# Key builders: the ONLY place in the codebase that knows the key formats.
# ---------------------------------------------------------------------------
def _pk(user_id):
    return f"USER#{user_id}"


def _sk(expense_id):
    return f"EXPENSE#{expense_id}"


def _gsi1sk(expense_date, expense_id):
    return f"DATE#{expense_date}#{expense_id}"


def _key(user_id, expense_id):
    return {"PK": _pk(user_id), "SK": _sk(expense_id)}


def _to_public(item):
    """Strip internal key attributes before data leaves the API."""
    return {k: v for k, v in item.items() if k not in _KEY_ATTRIBUTES}


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _is_condition_failure(error):
    return error.response["Error"]["Code"] == "ConditionalCheckFailedException"


# ---------------------------------------------------------------------------
# CRUD operations
# ---------------------------------------------------------------------------
def create_expense(user_id, expense_id, data):
    """AP1: save a new expense."""
    now = _now()
    item = {
        "PK": _pk(user_id),
        "SK": _sk(expense_id),
        "GSI1PK": _pk(user_id),
        "GSI1SK": _gsi1sk(data["date"], expense_id),
        "expenseId": expense_id,
        **data,
        "receiptStatus": "NONE",
        "createdAt": now,
        "updatedAt": now,
    }
    
    _table.put_item(Item=item, ConditionExpression="attribute_not_exists(PK)")
    return _to_public(item)


def get_expense(user_id, expense_id):
    """AP2: get one expense. Returns None if it doesn't exist for this user."""
    response = _table.get_item(Key=_key(user_id, expense_id))
    item = response.get("Item")
    return _to_public(item) if item else None


def list_expenses_for_month(user_id, month):
    """AP5: all of a user's expenses in one month (YYYY-MM), newest first."""
    query_args = {
        "IndexName": "GSI1",
        "KeyConditionExpression": (
            Key("GSI1PK").eq(_pk(user_id))
            & Key("GSI1SK").begins_with(f"DATE#{month}")
        ),
        "ScanIndexForward": False,  # descending order = newest first
    }
    items = []
    # DynamoDB returns at most 1 MB per call. If there is more,
    # it gives us LastEvaluatedKey, and we ask again from that point.
    while True:
        response = _table.query(**query_args)
        items.extend(response["Items"])
        if "LastEvaluatedKey" not in response:
            break
        query_args["ExclusiveStartKey"] = response["LastEvaluatedKey"]
    return [_to_public(item) for item in items]


def update_expense(user_id, expense_id, data):
    """AP3: replace an expense's editable fields. Returns None if not found."""
    # The date may have changed, so the GSI sort key must change with it.
    fields = {
        **data,
        "GSI1SK": _gsi1sk(data["date"], expense_id),
        "updatedAt": _now(),
    }
    to_remove = [f for f in OPTIONAL_FIELDS if f not in data]

    # "#name" placeholders protect us from DynamoDB reserved words
    # (for example, "date" is reserved and would cause an error).
    names = {f"#{name}": name for name in [*fields, *to_remove]}
    values = {f":{name}": value for name, value in fields.items()}
    expression = "SET " + ", ".join(f"#{name} = :{name}" for name in fields)
    if to_remove:
        expression += " REMOVE " + ", ".join(f"#{name}" for name in to_remove)

    try:
        response = _table.update_item(
            Key=_key(user_id, expense_id),
            UpdateExpression=expression,
            ConditionExpression="attribute_exists(PK)",  # only if it exists
            ExpressionAttributeNames=names,
            ExpressionAttributeValues=values,
            ReturnValues="ALL_NEW",
        )
    except ClientError as error:
        if _is_condition_failure(error):
            return None
        raise
    return _to_public(response["Attributes"])


def delete_expense(user_id, expense_id):
    """AP4: delete an expense. Returns False if it didn't exist."""
    try:
        _table.delete_item(
            Key=_key(user_id, expense_id),
            ConditionExpression="attribute_exists(PK)",
        )
    except ClientError as error:
        if _is_condition_failure(error):
            return False
        raise
    return True