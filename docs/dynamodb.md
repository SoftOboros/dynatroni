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

## Item Shape

Each DynamoDB item contains these attributes:

| Attribute | Type | Description |
|-----------|------|-------------|
| `cluster_name` | String | Partition key - Patroni scope/cluster name |
| `key` | String | Sort key - item type (e.g., `leader`, `config`, `members/node1`) |
| `value` | String | JSON-encoded data or raw string |
| `version` | Number | Microsecond timestamp for optimistic locking |
| `session` | String | UUID identifying the Patroni instance (leader/member keys only) |
| `ttl` | Number | Unix timestamp for DynamoDB TTL expiration (optional) |

**Example: leader key**
```json
{
  "cluster_name": "prod-db",
  "key": "leader",
  "value": "node1",
  "version": 1706745600000000,
  "session": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "ttl": 1706745660
}
```

**Example: member key**
```json
{
  "cluster_name": "prod-db",
  "key": "members/node1",
  "value": "{\"conn_url\": \"postgres://10.0.0.10:5432/postgres\", \"api_url\": \"http://10.0.0.10:8008/patroni\", ...}",
  "version": 1706745600000000,
  "session": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "ttl": 1706745720
}
```

## TTL Behavior

DynamoDB TTL automatically deletes expired items (eventually consistent, may linger up to 48 hours).

| Key Type | TTL Value | Notes |
|----------|-----------|-------|
| `leader` | `failover_time` | Leader lock validity window |
| `members/*` | `failover_time * 2` | Member heartbeat (2x to survive missed heartbeats) |
| `status` | `failover_time * 2` | Cluster status (2x for consistency with members) |
| `config`, `sync`, `failover`, `history`, `initialize`, `failsafe` | None | Persistent until explicitly deleted |

**Note:** Items without TTL persist indefinitely. Use `patronictl remove` or manual cleanup for decommissioned clusters.

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

## Leader Election Semantics

Dynatroni uses conditional writes throughout to ensure atomic leader election:

| Operation | Pattern | Condition |
|-----------|---------|-----------|
| **New leader (no existing)** | Conditional put | `attribute_not_exists(cluster_name)` |
| **Leader renewal (same session)** | Conditional update | `session = :our_session` |
| **TTL-expired takeover** | Conditional put | `ttl < :now` |
| **Config/sync updates** | Conditional put | `version = :expected OR attribute_not_exists` |

**Atomic TTL-expired takeover:** When multiple nodes detect an expired leader TTL simultaneously, the conditional write `ttl < :now` ensures only one succeeds. Nodes that lose the race receive `ConditionalCheckFailedException` and will see the new leader on their next read.

This handles the case where DynamoDB TTL cleanup hasn't yet removed the expired item - we check `ttl < :now` rather than `attribute_not_exists`, allowing takeover while the item still physically exists.

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
