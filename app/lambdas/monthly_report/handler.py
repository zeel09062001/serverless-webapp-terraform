"""
Monthly summary: emails each user a summary of last month's spending.

Triggered by EventBridge Scheduler on the 1st of each month, or run by
hand with {"month": "YYYY-MM"} for testing.

Safe to run more than once: before emailing a user, we write a
REPORT#<month> marker with a conditional write. If the marker already
exists, that user was already handled and is skipped.
"""
import html
import json
import logging
import os
import re
from collections import defaultdict
from datetime import datetime, timedelta, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
_cognito = boto3.client("cognito-idp")
_ses = boto3.client("sesv2")

USER_POOL_ID = os.environ["USER_POOL_ID"]
SENDER_EMAIL = os.environ["SENDER_EMAIL"]
MONTH_RE = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")


def log(message, **details):
    logger.info(json.dumps({"message": message, **details}))


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# -----------------------------------------------------------------------------
# Which month?
# -----------------------------------------------------------------------------
def month_to_report(event):
    if "month" in event:  # manual run
        if not MONTH_RE.match(str(event["month"])):
            raise ValueError("month must be in YYYY-MM format")
        return event["month"]

    # Scheduled run: Scheduler tells us when this run was SCHEDULED (UTC).
    # One day earlier is always inside the previous month, in any time zone.
    scheduled = datetime.fromisoformat(event["scheduledTime"].replace("Z", "+00:00"))
    return (scheduled - timedelta(days=1)).strftime("%Y-%m")


# -----------------------------------------------------------------------------
# Reading data
# -----------------------------------------------------------------------------
def confirmed_users():
    """Yields (userId, email) for every confirmed, enabled user."""
    paginator = _cognito.get_paginator("list_users")
    for page in paginator.paginate(UserPoolId=USER_POOL_ID, PaginationConfig={"PageSize": 60}):
        for user in page["Users"]:
            if not user.get("Enabled") or user.get("UserStatus") != "CONFIRMED":
                continue
            attributes = {a["Name"]: a["Value"] for a in user.get("Attributes", [])}
            if attributes.get("sub") and attributes.get("email"):
                yield attributes["sub"], attributes["email"]


def expenses_for_month(user_id, month):
    """Same GSI query as the API's list route."""
    query_args = {
        "IndexName": "GSI1",
        "KeyConditionExpression": (
            Key("GSI1PK").eq(f"USER#{user_id}")
            & Key("GSI1SK").begins_with(f"DATE#{month}")
        ),
    }
    items = []
    while True:
        response = _table.query(**query_args)
        items.extend(response["Items"])
        if "LastEvaluatedKey" not in response:
            return items
        query_args["ExclusiveStartKey"] = response["LastEvaluatedKey"]


# -----------------------------------------------------------------------------
# Building the email
# -----------------------------------------------------------------------------
def money(cents):
    """1250 -> "$12.50", using whole numbers only (no floating point)."""
    return f"${cents // 100:,}.{cents % 100:02d}"


def summarize(expenses):
    by_category = defaultdict(int)
    for expense in expenses:
        by_category[expense["category"]] += int(expense["amountCents"])
    biggest = max(expenses, key=lambda e: int(e["amountCents"]))
    return {
        "count": len(expenses),
        "total": sum(by_category.values()),
        "categories": sorted(by_category.items(), key=lambda item: item[1], reverse=True),
        "biggest": biggest,
    }


def build_email(month, summary):
    label = datetime.strptime(month, "%Y-%m").strftime("%B %Y")  # "October 2026"
    biggest = summary["biggest"]
    biggest_line = (
        f"{biggest['merchant']} ({money(int(biggest['amountCents']))}) on {biggest['date']}"
    )

    # Plain-text version, for email apps that don't show HTML
    lines = [
        f"Your spending in {label}",
        "",
        f"Total: {money(summary['total'])} across {summary['count']} expense(s)",
        "",
        "By category:",
    ]
    lines += [f"  {category.title()}: {money(cents)}" for category, cents in summary["categories"]]
    lines += ["", f"Biggest expense: {biggest_line}"]
    text_body = "\n".join(lines)

    # HTML version. html.escape() on everything that came from users:
    # a merchant name is user input, so it must never become HTML.
    rows = "".join(
        f"<tr><td style='padding:4px 16px 4px 0'>{html.escape(category.title())}</td>"
        f"<td style='text-align:right'>{money(cents)}</td></tr>"
        for category, cents in summary["categories"]
    )
    html_body = (
        "<html><body style='font-family:sans-serif;color:#1f1f1f'>"
        f"<h2>Your spending in {label}</h2>"
        f"<p><strong>Total: {money(summary['total'])}</strong> "
        f"across {summary['count']} expense(s)</p>"
        f"<table>{rows}</table>"
        f"<p>Biggest expense: {html.escape(biggest_line)}</p>"
        "</body></html>"
    )

    return f"Your {label} spending summary", text_body, html_body


# -----------------------------------------------------------------------------
# Idempotency markers: one REPORT#<month> item per user, per month
# -----------------------------------------------------------------------------
def _marker_key(user_id, month):
    return {"PK": f"USER#{user_id}", "SK": f"REPORT#{month}"}


def claim_report(user_id, month):
    """Atomically record "we're handling this". False if already claimed."""
    try:
        _table.put_item(
            Item={**_marker_key(user_id, month), "status": "SENDING", "createdAt": now_iso()},
            ConditionExpression="attribute_not_exists(PK)",
        )
        return True
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def finish_report(user_id, month, status):
    _table.update_item(
        Key=_marker_key(user_id, month),
        UpdateExpression="SET #status = :status, finishedAt = :finished",
        ExpressionAttributeNames={"#status": "status"},  # "status" is a reserved word
        ExpressionAttributeValues={":status": status, ":finished": now_iso()},
    )


def release_report(user_id, month):
    """Remove the claim so a retry can try this user again."""
    _table.delete_item(Key=_marker_key(user_id, month))


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
def send_email(to_address, subject, text_body, html_body):
    _ses.send_email(
        FromEmailAddress=SENDER_EMAIL,
        Destination={"ToAddresses": [to_address]},
        Content={
            "Simple": {
                "Subject": {"Data": subject},
                "Body": {"Text": {"Data": text_body}, "Html": {"Data": html_body}},
            }
        },
    )


def report_for_user(user_id, email, month):
    """Returns the outcome for this user, as a short label."""
    expenses = expenses_for_month(user_id, month)
    if not expenses:
        finish_report(user_id, month, "SKIPPED_NO_EXPENSES")
        return "no_expenses"

    subject, text_body, html_body = build_email(month, summarize(expenses))
    try:
        send_email(email, subject, text_body, html_body)
    except ClientError as error:
        if error.response["Error"]["Code"] == "MessageRejected":
            # SES sandbox: this recipient isn't verified. Retrying won't help.
            finish_report(user_id, month, "SKIPPED_UNVERIFIED")
            return "unverified"
        raise

    finish_report(user_id, month, "SENT")
    return "sent"


def handler(event, context):
    month = month_to_report(event)
    counts = defaultdict(int)
    failed = 0

    for user_id, email in confirmed_users():
        if not claim_report(user_id, month):
            counts["already_handled"] += 1
            continue
        try:
            outcome = report_for_user(user_id, email, month)
            counts[outcome] += 1
            log("User handled", userId=user_id, month=month, outcome=outcome)
        except Exception:
            # Release the claim so the retry can try this user again
            release_report(user_id, month)
            failed += 1
            logger.exception("Report failed for user %s", user_id)

    summary = {"month": month, **counts, "failed": failed}
    log("Monthly report run finished", **summary)

    if failed:
        # Raising makes Lambda retry the whole run. Users already handled are
        # skipped by their markers, so ONLY the failed users are retried.
        raise RuntimeError(f"{failed} report(s) failed and will be retried")
    return summary