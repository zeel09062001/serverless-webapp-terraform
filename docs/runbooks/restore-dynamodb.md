# Runbook: Recover deleted or corrupted expenses (DynamoDB + S3)

| | |
|---|---|
| **Applies to** | `serverless-webapp` dev and prod (`us-east-1`) |
| **Data stores** | DynamoDB table `serverless-webapp-<env>-expenses`, S3 bucket `serverless-webapp-<env>-receipts-716145798645` |
| **Last tested** | 2026-10-23, in dev (see [Drill record](#drill-record-2026-10-23)) |
| **Measured RTO** | __RTO_MINUTES__ minutes (drill, including tooling delays) |
| **Expected RPO** | About 5 minutes (PITR's restorable-time lag) |

---

## When to use this runbook

Use it when expenses have been **deleted or corrupted** and the data must come back, for example:

- A bad release deleted or overwrote items.
- A script or manual command changed the wrong data.
- A user reports expenses or receipts that have disappeared.

**Do not use it** for a single expense that a user can simply re-enter, or for problems that aren't data loss (errors, slowness). Check the dashboard and alarms first.

---

## Key facts to know before starting

- **Point-in-time recovery (PITR)** is on for every expenses table. It can restore to **any second in the last 35 days**.
- The **latest restorable time lags about 5 minutes** behind the present. Changes from the last few minutes may not be restorable yet.
- **A PITR restore never changes the live table.** It creates a **new** table with the data as it was at the chosen moment. Recovery means copying the lost items back.
- The restored table does **not** get PITR, deletion protection, or tags, and is **not managed by Terraform**. Delete it when recovery is finished.
- **Receipts bucket versioning** keeps deleted and overwritten files for **30 days** (lifecycle rule). A "deleted" file is hidden behind a **delete marker**, and removing the marker brings it back.
- In **prod**, the table and user pool have **deletion protection**.

---

## Prerequisites (check these BEFORE an incident)

- [ ] AWS CLI configured, with permission to restore DynamoDB tables and manage object versions in the receipts bucket.
- [ ] A local copy of this repository (for `scripts/restore_missing_items.py`).
- [ ] Python 3.12 with `boto3`:
  ```bash
  python3.12 -m venv .venv
  source .venv/bin/activate
  python -m pip install -r requirements-dev.txt
  ```
- [ ] **Fallback with no local setup:** AWS **CloudShell** (console → CloudShell icon, region `us-east-1`) has the AWS CLI, Python and `boto3` preinstalled and uses your console login. Clone the repository there.

> Use `deactivate` to leave the virtual environment. **`exit` closes the whole terminal** and loses every variable set in it.

---

## Step 0: Start an incident log

Before touching anything, create a log file. Every timestamp, ID and decision goes in it. If the terminal closes, nothing is lost.

```bash
mkdir -p ~/incidents
LOG=~/incidents/$(date -u +%Y%m%d-%H%M)-data-recovery.txt
echo "Incident started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOG"
echo "LOG=$LOG"
```

Set the environment's names, and record them:

```bash
cd ~/serverless-webapp-terraform
ENV=dev    # or: prod

TABLE=serverless-webapp-$ENV-expenses
RESTORED=serverless-webapp-$ENV-expenses-restore-$(date -u +%Y%m%d%H%M)
RECEIPTS=serverless-webapp-$ENV-receipts-716145798645
POOL_ID=$(cd envs/$ENV && terraform output -raw user_pool_id)

cat >> "$LOG" << EOF
ENV=$ENV
TABLE=$TABLE
RESTORED=$RESTORED
RECEIPTS=$RECEIPTS
POOL_ID=$POOL_ID
EOF
```

To reload everything in a new terminal: `source <(grep = "$LOG")` (set `LOG` to the file's path first).

---

## Step 1: Contain the damage

1. **Stop the cause first.** Roll back the release (revert the commit and let the pipeline deploy), or stop the script.
2. **Identify the affected users.** For a user who reported it, find their ID:
   ```bash
   SUB=$(aws cognito-idp admin-get-user --user-pool-id $POOL_ID \
     --username <user-email> \
     --query "UserAttributes[?Name=='sub'].Value" --output text)
   echo "SUB=$SUB" >> "$LOG"
   ```
3. **Find the last known good time (UTC).** The API access logs record every request with the user's ID. To find when deletions began:
   ```bash
   QUERY_ID=$(aws logs start-query \
     --log-group-name /aws/apigateway/serverless-webapp-$ENV-api \
     --start-time $(date -v-24H +%s) --end-time $(date +%s) \
     --query-string "fields @timestamp, routeKey, status
       | filter userId = '$SUB' and routeKey like /DELETE|PUT/
       | sort @timestamp asc" \
     --query queryId --output text)
   sleep 8
   aws logs get-query-results --query-id $QUERY_ID \
     --query 'results[].[0].value' --output text
   ```
   Choose a **last known good** time just **before** the first harmful request, and record it:
   ```bash
   GOOD_TIME=<YYYY-MM-DDTHH:MM:SSZ>
   echo "GOOD_TIME=$GOOD_TIME" >> "$LOG"
   ```

---

## Step 2: Check the restore point is available

```bash
aws dynamodb describe-continuous-backups --table-name $TABLE \
  --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.{earliest: EarliestRestorableDateTime, latest: LatestRestorableDateTime}'
```

`GOOD_TIME` must be between `earliest` and `latest`. If it's later than `latest`, wait a few minutes and check again.

---

## Step 3: Restore the table (creates a NEW table)

```bash
echo "Restore started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"

aws dynamodb restore-table-to-point-in-time \
  --source-table-name $TABLE \
  --target-table-name $RESTORED \
  --restore-date-time "$GOOD_TIME" \
  --query 'TableDescription.TableStatus'

aws dynamodb wait table-exists --table-name $RESTORED
echo "Restored table active: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

The waiter gives up after about 10 minutes. If it times out, run the `wait` command again: large tables can take much longer to restore.

Check the restored table contains the lost data:

```bash
aws dynamodb query --table-name $RESTORED \
  --key-condition-expression "PK = :pk AND begins_with(SK, :prefix)" \
  --expression-attribute-values "{\":pk\": {\"S\": \"USER#$SUB\"}, \":prefix\": {\"S\": \"EXPENSE#\"}}" \
  --query 'Items[].[SK.S, merchant.S, receiptStatus.S]' \
  --output table
```

---

## Step 4: Recover the missing items (dry run FIRST)

```bash
source .venv/bin/activate

# 1. Dry run: shows what WOULD be restored. Changes nothing.
python scripts/restore_missing_items.py $RESTORED $TABLE --user $SUB
```

**Read the list carefully before applying.** It must contain only the items that were lost. If it also lists items the user **deliberately deleted** after `GOOD_TIME`, do **not** apply: the script would bring them back. Restore those items individually instead, or narrow the restore point.

```bash
# 2. Apply
python scripts/restore_missing_items.py $RESTORED $TABLE --user $SUB --apply
echo "Items restored: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

The script **never overwrites** an item that exists in the live table, so anything changed after the incident is kept. Repeat steps 1–4 for each affected user.

---

## Step 5: Recover the receipt files

Every restored expense with `receiptStatus = ATTACHED` needs its file back, or the app will promise a receipt it can't serve. List the restored expenses that had receipts:

```bash
aws dynamodb query --table-name $TABLE \
  --key-condition-expression "PK = :pk AND begins_with(SK, :prefix)" \
  --filter-expression "receiptStatus = :attached" \
  --expression-attribute-values "{\":pk\": {\"S\": \"USER#$SUB\"}, \":prefix\": {\"S\": \"EXPENSE#\"}, \":attached\": {\"S\": \"ATTACHED\"}}" \
  --query 'Items[].expenseId.S' --output text
```

For each expense ID, remove its delete marker (if it has one):

```bash
EXPENSE_ID=<expense-id>
MARKER=$(aws s3api list-object-versions --bucket $RECEIPTS \
  --prefix "receipts/$SUB/$EXPENSE_ID" \
  --query 'DeleteMarkers[?IsLatest].VersionId' --output text)

if [ -n "$MARKER" ] && [ "$MARKER" != "None" ]; then
  aws s3api delete-object --bucket $RECEIPTS \
    --key "receipts/$SUB/$EXPENSE_ID" --version-id "$MARKER"
  echo "Receipt restored for $EXPENSE_ID: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
fi

aws s3 ls "s3://$RECEIPTS/receipts/$SUB/$EXPENSE_ID"
```

> **Careful:** deleting a **delete marker** by version ID brings a file **back**. Deleting a **file version** by version ID destroys it **permanently**. Only ever pass the marker's version ID here.

Deleted receipt versions are only kept for **30 days**.

---

## Step 6: Verify through the application

Recovery is not complete until it's verified the way a user would see it.

- In the website, sign in as (or with) the affected user and check the affected months.
- Open at least one restored receipt.
- Or through the API with a valid token:
  ```bash
  curl -s "$API/expenses?month=<YYYY-MM>" -H "Authorization: Bearer $TOKEN" | python3 -m json.tool
  curl -s "$API/expenses/<expense-id>/receipt" -H "Authorization: Bearer $TOKEN" | python3 -m json.tool
  ```

```bash
echo "Recovery verified: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

**RTO** = time from the incident to this "verified" timestamp.

---

## Step 7: Clean up

The restored table isn't managed by Terraform and would otherwise be forgotten (and billed):

```bash
aws dynamodb delete-table --table-name $RESTORED --query 'TableDescription.TableStatus'
echo "Restored table deleted: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
```

Then `deactivate` the virtual environment.

---

## Step 8: Follow up

- Tell the affected users their data has been restored.
- Write a short **incident report** from the log: timeline, cause, impact, what was restored, and actions to prevent it happening again.
- Run `terraform plan` in the affected environment: it should show **No changes**.

---

## Other scenarios

**The whole table was deleted.** Prod has deletion protection, so this should not happen there. When a table with PITR is deleted, DynamoDB keeps a system backup of it for 35 days (see **DynamoDB → Backups** in the console). Restore it to the **original** table name, then bring it back under Terraform with `terraform import` for the table resource, and re-apply so PITR, deletion protection and tags are set again. Practice this in dev before ever needing it in prod.

**Corrupted, not deleted.** `restore_missing_items.py` deliberately won't overwrite existing items. To replace corrupted items with their earlier versions, copy the specific items from the restored table by hand (`get-item` from `$RESTORED`, `put-item` into `$TABLE`), one at a time, after confirming each one.

**Many users affected.** Run steps 1–5 for each user, or extend the script to accept a list of user IDs. Never remove the "missing items only" rule.

---

## Known limitations

- Restored tables don't copy PITR, deletion protection, or tags.
- The most recent ~5 minutes of changes may not be restorable (PITR lag).
- Recovery is per user. Whole-table recovery needs extra care to avoid resurrecting deliberately deleted data.
- Receipt files can only be recovered within 30 days.
- Dev and prod share one AWS account, so account-level limits and permissions are shared (see the closure report's future work).

---

## Drill record: 2026-10-23

**Environment:** dev. **Scenario:** a buggy release deletes one user's expenses, including one with a receipt.

### What was done

1. Created three test expenses in November 2026 for a drill user (`640894c8-a061-7091-f072-8ed238b07c76`):

   | Expense | ID | Amount | Receipt |
   |---|---|---|---|
   | DR drill A | `2f7e9fe3-1e2c-4d0c-960f-117f28a7eb13` | $11.00 | Yes |
   | DR drill B | `c01bfaaf-e9fa-448e-857a-aafc884f7b62` | $22.00 | No |
   | DR drill C | `81ea4363-ac45-4737-a5f5-0ecf7feee0a1` | $33.00 | No |

2. Recorded the last known good time, and waited until it was within PITR's restorable window.
3. Deleted all three expenses through the API (the "disaster"), which also hid Drill A's receipt behind a delete marker.
4. Restored the table to the last known good time, into `serverless-webapp-dev-expenses-restore-drill`.
5. Dry-ran the recovery script: it listed **exactly the three drill expenses** and nothing else.
6. Applied the recovery: **3 items restored**, with their original IDs.
7. Removed the delete marker from Drill A's receipt.
8. Verified through the API: all three expenses listed for November 2026, Drill A `ATTACHED`, and its receipt served by a working download link.
9. Deleted the restored table.

### Timeline (UTC)

| Event | Time |
|---|---|
| Disaster: last drill expense deleted | __DISASTER_TIME__ |
| Recovery verified (receipt download link issued) | 2026-10-23 16:25:27 |
| **Total recovery time (RTO)** | **__RTO_MINUTES__ minutes** |

The RTO includes the delays caused by the findings below. Without them, recovery would have been noticeably faster: the restore itself and the data copy took only a few minutes.

### Results

| Check | Result |
|---|---|
| Restored table contained the lost items | ✅ |
| Dry run listed only the lost items | ✅ |
| Items restored with original IDs | ✅ 3 of 3 |
| Receipt file restored and served | ✅ |
| Data consistent between DynamoDB and S3 | ✅ |
| No other data changed | ✅ (script never overwrites) |

### Findings and actions

| # | Finding | Action taken |
|---|---|---|
| 1 | The recovery script's dependency (`boto3`) wasn't installed when it was needed. | Added the **Prerequisites** section, with AWS CloudShell as a fallback. |
| 2 | Key values (IDs, table names, times) existed only in one terminal, and were lost when it was closed with `exit`. | Added **Step 0: incident log**, and the note about `deactivate` vs `exit`. |
| 3 | The recovery timer was lost with the terminal. | Timestamps are now written to the incident log at every step. The timeline was reconstructed from API Gateway access logs and DynamoDB table metadata. |

### Next drill

- Repeat in **dev** using only this runbook, ideally run by someone else, to check it's complete.
- Practice the **whole-table deletion** scenario in dev, including `terraform import`.
- Recommended frequency: every 3–6 months, and after any change to the table or bucket design.
