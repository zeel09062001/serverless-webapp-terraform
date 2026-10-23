"""Unit tests for the receipt worker, running against a fake AWS (moto)."""
import json

import boto3
import pytest

from helpers import s3_message

PNG = b"\x89PNG\r\n\x1a\n" + b"rest of the image"  # starts with the real PNG magic number
USER = "user-a"
EXPENSE_ID = "2f1b6a3e-8c4d-4e1f-9a2b-3c4d5e6f7a8b"
KEY = f"receipts/{USER}/{EXPENSE_ID}"
EXPENSE_KEY = {"PK": f"USER#{USER}", "SK": f"EXPENSE#{EXPENSE_ID}"}


@pytest.fixture
def table(aws):
    """The table, with one expense waiting for a receipt."""
    table = boto3.resource("dynamodb").Table("test-expenses")
    table.put_item(Item={**EXPENSE_KEY, "receiptStatus": "NONE"})
    return table


def upload(body, content_type):
    boto3.client("s3").put_object(Bucket="test-receipts", Key=KEY, Body=body, ContentType=content_type)


def receipt_status(table):
    return table.get_item(Key=EXPENSE_KEY)["Item"]["receiptStatus"]


def file_exists():
    return boto3.client("s3").list_objects_v2(Bucket="test-receipts", Prefix=KEY)["KeyCount"] > 0


def run(worker, *messages):
    """Calls the worker with a batch of SQS messages, like Lambda does."""
    return worker.handler({"Records": list(messages)}, None)


def test_genuine_png_is_attached(worker, table):
    upload(PNG, "image/png")
    result = run(worker, s3_message(KEY, size=len(PNG)))

    assert result == {"batchItemFailures": []}
    assert receipt_status(table) == "ATTACHED"
    assert file_exists()


@pytest.mark.parametrize(
    "body, declared_type",
    [
        (b"I am not really an image", "image/png"),  # fake file
        (PNG, "image/jpeg"),                         # real PNG, wrong label
    ],
)
def test_fake_or_mislabelled_files_are_rejected_and_deleted(worker, table, body, declared_type):
    upload(body, declared_type)
    result = run(worker, s3_message(KEY))

    assert result == {"batchItemFailures": []}  # handled, not a failure
    assert receipt_status(table) == "REJECTED"
    assert not file_exists()


def test_processing_the_same_message_twice_is_safe(worker, table):
    """SQS is at-least-once: duplicates must not cause errors or wrong results."""
    upload(PNG, "image/png")
    message = s3_message(KEY)

    run(worker, message)
    result = run(worker, message)

    assert result == {"batchItemFailures": []}
    assert receipt_status(table) == "ATTACHED"


def test_orphaned_file_is_removed_when_the_expense_was_deleted(worker, aws):
    upload(PNG, "image/png")  # note: no expense exists for this file
    result = run(worker, s3_message(KEY))

    assert result == {"batchItemFailures": []}
    assert not file_exists()
    item = boto3.resource("dynamodb").Table("test-expenses").get_item(Key=EXPENSE_KEY)
    assert "Item" not in item  # the worker did NOT create a half-empty expense


def test_s3_test_event_is_ignored(worker, aws):
    message = {"messageId": "test-event", "body": json.dumps({"Event": "s3:TestEvent"})}
    assert run(worker, message) == {"batchItemFailures": []}


def test_a_bad_message_fails_alone_without_blocking_the_others(worker, table):
    upload(PNG, "image/png")
    bad = {"messageId": "bad", "body": "this is not JSON"}
    good = s3_message(KEY, message_id="good")

    result = run(worker, bad, good)

    assert result == {"batchItemFailures": [{"itemIdentifier": "bad"}]}  # only the bad one retried
    assert receipt_status(table) == "ATTACHED"  # the good one was still processed