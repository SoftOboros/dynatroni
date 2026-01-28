<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# DynamoDB Setup

Dynatroni stores cluster state in DynamoDB. DynamoDB acts as the arbiter for
leader election and membership using conditional writes and TTLs.

## Table Schema

- Partition Key: `cluster_name` (String)
- Sort Key: `key` (String)
- TTL attribute: `ttl` (Number)

## Create the Table

```bash
aws dynamodb create-table \
  --table-name patroni-dynamodb \
  --attribute-definitions \
    AttributeName=cluster_name,AttributeType=S \
    AttributeName=key,AttributeType=S \
  --key-schema \
    AttributeName=cluster_name,KeyType=HASH \
    AttributeName=key,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST
```

Enable TTL:

```bash
aws dynamodb update-time-to-live \
  --table-name patroni-dynamodb \
  --time-to-live-specification "Enabled=true,AttributeName=ttl"
```

## IAM Permissions

Minimum permissions for the node IAM role or AWS credentials:

```json
{
  "Effect": "Allow",
  "Action": [
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:UpdateItem",
    "dynamodb:DeleteItem",
    "dynamodb:Query",
    "dynamodb:BatchWriteItem"
  ],
  "Resource": "arn:aws:dynamodb:REGION:ACCOUNT:table/patroni-dynamodb"
}
```

## Environment / Isolation Tips

- Use a **dedicated table per environment** (e.g., `patroni-dynamodb-dev`).
- If multiple clusters share a table, ensure unique `scope` values so
  `cluster_name` does not collide.
- TTL cleanup is eventually consistent; expired items may linger briefly.

## DynamoDB Local (Optional)

For local testing, point `endpoint_url` in your Patroni config to a local
DynamoDB instance:

```yaml
dynamodb:
  region: us-east-1
  table_name: patroni-dynamodb-local
  endpoint_url: http://localhost:8000
```
