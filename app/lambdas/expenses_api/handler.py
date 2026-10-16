"""
Expenses API: the HTTP layer.
Reads the request, works out who the user is, validates input,
calls the repository, and builds the HTTP response.
"""
import base64
import json
import logging
import re
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import repository

logger = logging.getLogger()
logger.setLevel(logging.INFO)

CATEGORIES = {"food", "travel", "bills", "shopping", "entertainment", "health", "other"}
MAX_AMOUNT_CENTS = 100_000_000  # $1,000,000
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MONTH_RE = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")
CURRENCY_RE = re.compile(r"^[A-Z]{3}$")


class BadRequest(Exception):
    """Raised when the client sent invalid input. Becomes HTTP 400."""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _json_default(value):
    """DynamoDB returns numbers as Decimal, which json.dumps can't handle."""
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError(f"Cannot serialise {type(value).__name__}")


def response(status_code, body=None):
    result = {"statusCode": status_code, "headers": {"Content-Type": "application/json"}}
    if body is not None:
        result["body"] = json.dumps(body, default=_json_default)
    return result


def not_found():
    return response(404, {"error": "Expense not found"})


def get_user_id(event):
    """The user's ID from the login token. API Gateway has already verified it."""
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )
    return claims.get("sub")


def path_expense_id(event):
    """Read {id} from the URL. Returns None unless it's a valid UUID."""
    raw = (event.get("pathParameters") or {}).get("id", "")
    try:
        return str(uuid.UUID(raw))
    except ValueError:
        return None


def parse_body(event):
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    try:
        body = json.loads(raw)
    except json.JSONDecodeError:
        raise BadRequest("Request body must be valid JSON")
    if not isinstance(body, dict):
        raise BadRequest("Request body must be a JSON object")
    return body


def validate_expense(body):
    """Check every field and return ONLY the fields we allow to be stored."""
    amount = body.get("amountCents")
    if (
        not isinstance(amount, int)
        or isinstance(amount, bool)
        or not 0 < amount <= MAX_AMOUNT_CENTS
    ):
        raise BadRequest("amountCents must be a whole number between 1 and 100000000")

    category = body.get("category")
    if category not in CATEGORIES:
        raise BadRequest(f"category must be one of: {', '.join(sorted(CATEGORIES))}")

    merchant = body.get("merchant")
    if not isinstance(merchant, str) or not 1 <= len(merchant.strip()) <= 100:
        raise BadRequest("merchant must be text between 1 and 100 characters")

    expense_date = body.get("date")
    if not isinstance(expense_date, str) or not DATE_RE.match(expense_date):
        raise BadRequest("date must be in YYYY-MM-DD format")
    try:
        datetime.strptime(expense_date, "%Y-%m-%d")
    except ValueError:
        raise BadRequest("date is not a real calendar date")

    currency = body.get("currency", "USD")
    if not isinstance(currency, str) or not CURRENCY_RE.match(currency):
        raise BadRequest("currency must be a 3-letter code like USD")

    clean = {
        "amountCents": amount,
        "currency": currency,
        "category": category,
        "merchant": merchant.strip(),
        "date": expense_date,
    }

    note = body.get("note")
    if note is not None:
        if not isinstance(note, str) or len(note) > 500:
            raise BadRequest("note must be text up to 500 characters")
        if note.strip():
            clean["note"] = note.strip()

    return clean


# ---------------------------------------------------------------------------
# Route handlers: one function per API route
# ---------------------------------------------------------------------------
def handle_create(user_id, event):
    data = validate_expense(parse_body(event))
    expense = repository.create_expense(user_id, str(uuid.uuid4()), data)
    return response(201, expense)


def handle_list(user_id, event):
    params = event.get("queryStringParameters") or {}
    month = params.get("month") or datetime.now(timezone.utc).strftime("%Y-%m")
    if not MONTH_RE.match(month):
        raise BadRequest("month must be in YYYY-MM format")
    expenses = repository.list_expenses_for_month(user_id, month)
    return response(200, {"month": month, "count": len(expenses), "expenses": expenses})


def handle_get(user_id, event):
    expense_id = path_expense_id(event)
    expense = repository.get_expense(user_id, expense_id) if expense_id else None
    return response(200, expense) if expense else not_found()


def handle_update(user_id, event):
    expense_id = path_expense_id(event)
    if not expense_id:
        return not_found()
    data = validate_expense(parse_body(event))
    expense = repository.update_expense(user_id, expense_id, data)
    return response(200, expense) if expense else not_found()


def handle_delete(user_id, event):
    expense_id = path_expense_id(event)
    if expense_id and repository.delete_expense(user_id, expense_id):
        return response(204)
    return not_found()


ROUTES = {
    "POST /expenses": handle_create,
    "GET /expenses": handle_list,
    "GET /expenses/{id}": handle_get,
    "PUT /expenses/{id}": handle_update,
    "DELETE /expenses/{id}": handle_delete,
}


# ---------------------------------------------------------------------------
# Entry point: Lambda calls this for every request
# ---------------------------------------------------------------------------
def handler(event, context):
    route_key = event.get("routeKey")
    logger.info(json.dumps({"requestId": context.aws_request_id, "route": route_key}))

    user_id = get_user_id(event)
    if not user_id:
        return response(401, {"error": "Unauthorized"})

    route_handler = ROUTES.get(route_key)
    if route_handler is None:
        return response(404, {"error": "Route not found"})

    try:
        return route_handler(user_id, event)
    except BadRequest as error:
        return response(400, {"error": str(error)})
    except Exception:
        # Log full details for us; return a generic message to the client.
        logger.exception("Unhandled error")
        return response(500, {"error": "Internal server error"})