"""
Shared test setup, loaded automatically by pytest.

Each test that asks for a fixture below gets:
  - a FRESH fake AWS (moto), with the table and bucket already created
  - FRESH copies of the Lambda modules, connected to that fake AWS
Nothing here ever talks to real AWS.
"""
import importlib
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

ROOT = Path(__file__).resolve().parents[1]
API_DIR = ROOT / "app" / "lambdas" / "expenses_api"
WORKER_DIR = ROOT / "app" / "lambdas" / "receipt_worker"
REPORT_DIR = ROOT / "app" / "lambdas" / "monthly_report"

TABLE_NAME = "test-expenses"
BUCKET_NAME = "test-receipts"


def create_table():
    """Same keys and index as modules/database (keep them in sync!)."""
    boto3.client("dynamodb").create_table(
        TableName=TABLE_NAME,
        BillingMode="PAY_PER_REQUEST",
        AttributeDefinitions=[
            {"AttributeName": name, "AttributeType": "S"}
            for name in ("PK", "SK", "GSI1PK", "GSI1SK")
        ],
        KeySchema=[
            {"AttributeName": "PK", "KeyType": "HASH"},
            {"AttributeName": "SK", "KeyType": "RANGE"},
        ],
        GlobalSecondaryIndexes=[
            {
                "IndexName": "GSI1",
                "KeySchema": [
                    {"AttributeName": "GSI1PK", "KeyType": "HASH"},
                    {"AttributeName": "GSI1SK", "KeyType": "RANGE"},
                ],
                "Projection": {"ProjectionType": "ALL"},
            }
        ],
    )


@pytest.fixture
def aws(monkeypatch):
    """A fresh, empty fake AWS for one test."""
    # Fake credentials: if anything ever tried to reach REAL AWS, it would fail
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

    # The same environment variables Terraform gives the Lambdas
    monkeypatch.setenv("TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("RECEIPTS_BUCKET", BUCKET_NAME)
    monkeypatch.setenv("USER_POOL_ID", "us-east-1_TestPool")
    monkeypatch.setenv("SENDER_EMAIL", "reports@example.com")

    with mock_aws():
        create_table()
        boto3.client("s3").create_bucket(Bucket=BUCKET_NAME)
        yield


def load_lambda(directory, module_names):
    """
    Imports a Lambda's handler.py from its folder, fresh for each test.
    All three Lambdas have a file called handler.py, so we remove any
    previously imported copies first to avoid getting the wrong one.
    """
    for name in module_names:
        sys.modules.pop(name, None)
    sys.path.insert(0, str(directory))
    try:
        return importlib.import_module("handler")
    finally:
        sys.path.remove(str(directory))


@pytest.fixture
def api(aws):
    return load_lambda(API_DIR, ["handler", "repository", "storage"])


@pytest.fixture
def worker(aws):
    return load_lambda(WORKER_DIR, ["handler"])


@pytest.fixture
def report(aws):
    return load_lambda(REPORT_DIR, ["handler"])