"""Unit tests for the expenses API, running against a fake AWS (moto)."""
import uuid

import boto3
import pytest

from helpers import VALID_EXPENSE, api_event, call


def create(api, user="user-a", **overrides):
    """Create an expense through the API and return it."""
    status, body = call(api, api_event("POST /expenses", user, body={**VALID_EXPENSE, **overrides}))
    assert status == 201, body
    return body


# --- Creating -----------------------------------------------------------------

def test_create_returns_the_new_expense(api):
    expense = create(api)
    assert expense["amountCents"] == 1250
    assert expense["receiptStatus"] == "NONE"
    assert "PK" not in expense  # internal keys never leave the API
    uuid.UUID(expense["expenseId"])  # raises if it isn't a real UUID


def test_requests_without_a_user_are_rejected(api):
    status, _ = call(api, api_event("GET /expenses", user_id=None))
    assert status == 401


@pytest.mark.parametrize(
    "field, value",
    [
        ("amountCents", 12.5),         # decimals instead of cents
        ("amountCents", 0),
        ("amountCents", True),         # Python treats True as the integer 1!
        ("amountCents", "1250"),       # text, not a number
        ("category", "rockets"),
        ("merchant", ""),
        ("date", "2026-02-30"),        # not a real date
        ("date", "2026-1-5"),          # wrong format: would break date sorting
        ("currency", "usd"),
    ],
)
def test_invalid_input_is_rejected(api, field, value):
    status, body = call(api, api_event("POST /expenses", body={**VALID_EXPENSE, field: value}))
    assert status == 400
    assert "error" in body


def test_broken_json_is_rejected(api):
    status, _ = call(api, api_event("POST /expenses", body="{this is not json"))
    assert status == 400


def test_extra_fields_cannot_be_injected(api):
    """Mass assignment: fields the user shouldn't control are ignored."""
    expense = create(api, receiptStatus="ATTACHED", PK="USER#someone-else")
    assert expense["receiptStatus"] == "NONE"
    status, _ = call(api, api_event("GET /expenses/{id}", "user-a", expense["expenseId"]))
    assert status == 200  # still stored under user-a's own key


# --- Reading ------------------------------------------------------------------

def test_list_returns_only_that_month_newest_first(api):
    create(api, date="2026-10-05", merchant="Early October")
    create(api, date="2026-10-20", merchant="Late October")
    create(api, date="2026-09-30", merchant="September")

    status, body = call(api, api_event("GET /expenses", query={"month": "2026-10"}))
    assert status == 200
    assert [e["merchant"] for e in body["expenses"]] == ["Late October", "Early October"]


def test_users_cannot_touch_each_others_expenses(api):
    mine = create(api, user="user-a")

    status, _ = call(api, api_event("GET /expenses/{id}", "user-b", mine["expenseId"]))
    assert status == 404

    _, body = call(api, api_event("GET /expenses", "user-b", query={"month": "2026-10"}))
    assert body["expenses"] == []

    status, _ = call(api, api_event("PUT /expenses/{id}", "user-b", mine["expenseId"], body=VALID_EXPENSE))
    assert status == 404

    status, _ = call(api, api_event("DELETE /expenses/{id}", "user-b", mine["expenseId"]))
    assert status == 404


def test_invalid_expense_id_is_not_found(api):
    status, _ = call(api, api_event("GET /expenses/{id}", expense_id="not-a-uuid"))
    assert status == 404


# --- Updating -----------------------------------------------------------------

def test_update_replaces_fields_and_moves_month(api):
    expense = create(api, note="old note")
    changed = {**VALID_EXPENSE, "amountCents": 5000, "date": "2026-11-02"}  # no note

    status, body = call(api, api_event("PUT /expenses/{id}", expense_id=expense["expenseId"], body=changed))
    assert status == 200
    assert body["amountCents"] == 5000
    assert "note" not in body  # PUT replaces: the old note is removed

    _, october = call(api, api_event("GET /expenses", query={"month": "2026-10"}))
    _, november = call(api, api_event("GET /expenses", query={"month": "2026-11"}))
    assert october["count"] == 0
    assert november["count"] == 1  # GSI1SK was updated with the new date


def test_updating_a_missing_expense_does_not_create_one(api):
    missing_id = str(uuid.uuid4())
    status, _ = call(api, api_event("PUT /expenses/{id}", expense_id=missing_id, body=VALID_EXPENSE))
    assert status == 404
    status, _ = call(api, api_event("GET /expenses/{id}", expense_id=missing_id))
    assert status == 404


# --- Deleting -----------------------------------------------------------------

def test_delete_removes_the_expense_and_its_receipt(api):
    expense = create(api)
    s3 = boto3.client("s3")
    key = f"receipts/user-a/{expense['expenseId']}"
    s3.put_object(Bucket="test-receipts", Key=key, Body=b"receipt bytes")

    status, body = call(api, api_event("DELETE /expenses/{id}", expense_id=expense["expenseId"]))
    assert status == 204
    assert body is None
    assert s3.list_objects_v2(Bucket="test-receipts", Prefix=key)["KeyCount"] == 0

    status, _ = call(api, api_event("DELETE /expenses/{id}", expense_id=expense["expenseId"]))
    assert status == 404


# --- Receipts -----------------------------------------------------------------

def test_upload_form_is_locked_to_the_users_path_and_type(api):
    expense = create(api)
    status, body = call(api, api_event(
        "POST /expenses/{id}/receipt", expense_id=expense["expenseId"], body={"contentType": "image/png"},
    ))
    assert status == 200
    fields = body["upload"]["fields"]
    assert fields["key"] == f"receipts/user-a/{expense['expenseId']}"  # the SERVER chose the path
    assert fields["Content-Type"] == "image/png"


@pytest.mark.parametrize("content_type", ["text/html", "image/gif", None])
def test_upload_form_rejects_other_file_types(api, content_type):
    expense = create(api)
    status, _ = call(api, api_event(
        "POST /expenses/{id}/receipt", expense_id=expense["expenseId"], body={"contentType": content_type},
    ))
    assert status == 400


def test_no_upload_form_for_someone_elses_expense(api):
    expense = create(api, user="user-a")
    status, _ = call(api, api_event(
        "POST /expenses/{id}/receipt", "user-b", expense["expenseId"], body={"contentType": "image/png"},
    ))
    assert status == 404


def test_download_link_only_when_a_receipt_exists(api):
    expense = create(api)
    event = api_event("GET /expenses/{id}/receipt", expense_id=expense["expenseId"])

    status, _ = call(api, event)
    assert status == 404

    boto3.client("s3").put_object(
        Bucket="test-receipts", Key=f"receipts/user-a/{expense['expenseId']}", Body=b"x",
    )
    status, body = call(api, event)
    assert status == 200
    assert body["url"].startswith("https://")