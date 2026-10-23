"""
Copies items from a RESTORED DynamoDB table back into the LIVE table,
only where they're MISSING from the live table. Never overwrites.

Usage:
  python scripts/restore_missing_items.py <restored-table> <live-table> --user <sub> [--apply]

Without --apply, it's a dry run: it only reports what it WOULD restore.
--user limits recovery to one user's items, so we don't resurrect data
that other users deliberately deleted after the restore point.
"""
import argparse

import boto3
from botocore.exceptions import ClientError


def scan_items(table, pk):
    """All items in the restored table for one user. A scan is fine here:
    this is a one-off recovery job, not a request path."""
    query_args = {
        "FilterExpression": "PK = :pk",
        "ExpressionAttributeValues": {":pk": pk},
    }
    while True:
        page = table.scan(**query_args)
        yield from page["Items"]
        if "LastEvaluatedKey" not in page:
            return
        query_args["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("restored_table")
    parser.add_argument("live_table")
    parser.add_argument("--user", required=True, help="Cognito sub of the affected user")
    parser.add_argument("--apply", action="store_true", help="Actually write (default: dry run)")
    args = parser.parse_args()

    dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
    restored = dynamodb.Table(args.restored_table)
    live = dynamodb.Table(args.live_table)

    restored_count = present = 0
    for item in scan_items(restored, f"USER#{args.user}"):
        key = {"PK": item["PK"], "SK": item["SK"]}
        if "Item" in live.get_item(Key=key):
            present += 1  # exists in the live table: never overwrite newer data
            continue

        label = item.get("merchant", item["SK"])
        print(f"{'Restoring' if args.apply else 'Would restore'}: {item['SK']}  ({label})")
        if args.apply:
            try:
                live.put_item(Item=item, ConditionExpression="attribute_not_exists(PK)")
            except ClientError as error:
                if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    raise
                present += 1  # someone created it in the meantime: leave theirs alone
                continue
        restored_count += 1

    action = "Restored" if args.apply else "Would restore"
    print(f"\n{action}: {restored_count}   Already present (left alone): {present}")


if __name__ == "__main__":
    main()