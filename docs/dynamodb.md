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

## Leader Election Deep Dive

Dynatroni implements a distributed lock (leader election) using DynamoDB's conditional writes as the atomic primitive. This section details the mechanism, guarantees, and boundaries.

### The Mechanism: Conditional Writes as Semaphores

DynamoDB conditional writes are **atomic**: the condition check and the write happen as a single operation. If the condition fails, the write is rejected and the item is unchanged. This provides the foundation for distributed locking without requiring distributed transactions.

Each conditional write acts as a **compare-and-swap (CAS)** operation:
1. Read current state (optional, for decision making)
2. Attempt write with condition that encodes expected state
3. If condition fails → another node won; retry or back off
4. If condition succeeds → we hold the lock

### Operations and Their Conditions

| Operation | DynamoDB Call | Condition | Why This Condition |
|-----------|---------------|-----------|-------------------|
| **Acquire (new cluster)** | `PutItem` | `attribute_not_exists(cluster_name)` | Item must not exist; first writer wins |
| **Renew (extend TTL)** | `UpdateItem` | `session = :mine` | Only the current holder can extend |
| **Takeover (expired TTL)** | `PutItem` | `ttl < :now` | TTL must still be expired at write time |
| **Release (step down)** | `DeleteItem` | `session = :mine` | Only the current holder can release |

#### Acquire (New Cluster)

```
Node A                          DynamoDB                         Node B
   |                               |                                |
   |--PutItem(condition=not_exists)-->|                             |
   |                               |<--PutItem(condition=not_exists)--|
   |                               |                                |
   |<--Success--------------------|                                |
   |                               |--ConditionalCheckFailed------->|
```

Only one `PutItem` succeeds because `attribute_not_exists` fails once the item exists.

#### Renew (Current Leader)

```
Leader                          DynamoDB                         Replica
   |                               |                                |
   |--UpdateItem(session=ABC,ttl+60)->|                             |
   |<--Success--------------------|                                |
   |                               |                                |
   |                               |<--UpdateItem(session=XYZ,ttl+60)--|
   |                               |--ConditionalCheckFailed------->|
```

Only the node whose session matches can update. Replicas attempting to renew fail.

#### Takeover (Expired TTL)

This is the critical path for failover. When a leader dies, its TTL expires and replicas race to take over.

```
Time    Node A (sees expired)       DynamoDB                    Node B (sees expired)
  |            |                        |                              |
  |  Read: ttl=100, now=105            |           Read: ttl=100, now=105
  |            |                        |                              |
  |            |--PutItem(ttl<now)----->|                              |
  |            |                        |<-----PutItem(ttl<now)--------|
  |            |                        |                              |
  |            |<--Success (ttl=165)----|                              |
  |            |                        |----ConditionalCheckFailed--->|
```

**Why `ttl < :now` works:** At write time, DynamoDB checks the *current* TTL value. Node A's write sets `ttl=165`. When Node B's write arrives (even microseconds later), the condition `ttl < now` is **false** because `165 > 105`. Node B's write fails atomically.

#### Release (Step Down)

```
Leader                          DynamoDB
   |                               |
   |--DeleteItem(session=ABC)----->|
   |<--Success--------------------|
```

Only the holder (matching session) can delete. This prevents a stale/partitioned node from accidentally releasing a lock held by a new leader.

### Guarantees and Boundaries

#### What Dynatroni Guarantees

1. **Single leader at any instant**: Conditional writes ensure at most one node holds the lock
2. **Leader lease bounded by TTL**: A leader must renew before TTL expires or lose the lock
3. **Atomic transitions**: No intermediate state where two nodes both "hold" the lock
4. **Availability over consistency**: A surviving minority can elect a leader (no quorum needed)

#### What Dynatroni Does NOT Guarantee

1. **Fencing tokens**: There's no monotonic token to fence stale leaders at the application layer. PostgreSQL handles this via timeline IDs and WAL positions.

2. **Immediate leader detection**: A dead leader isn't detected until TTL expires. Detection time is bounded by `failover_time`.

3. **Clock synchronization**: TTL comparisons assume clocks are reasonably synchronized. Use NTP. Clock skew > TTL can cause issues.

4. **Network partition handling**: A partitioned leader that can still reach DynamoDB will keep renewing. Replicas won't take over until the leader loses DynamoDB connectivity.

### Race Condition Analysis

#### Race: Two nodes start simultaneously

Both attempt `attribute_not_exists`. DynamoDB serializes the writes; exactly one succeeds.

#### Race: Leader dies, two replicas race

Both read expired TTL, both attempt `PutItem` with `ttl < :now`. The first write to reach DynamoDB sets a future TTL. The second write's condition fails because TTL is no longer in the past.

#### Race: Slow leader renewal vs. eager replica

Leader's renewal is delayed (GC pause, network). Replica sees expired TTL and attempts takeover.

- If leader's `UpdateItem(session=mine)` arrives first: succeeds, TTL extended
- If replica's `PutItem(ttl<now)` arrives first: succeeds, new session
- If leader's update arrives after replica won: fails (`session` mismatch)

In all cases, exactly one node is leader after the dust settles.

### Timing Parameters

All timing derives from `failover_time` (default 60s):

| Parameter | Value | Purpose |
|-----------|-------|---------|
| TTL | `failover_time` | Leader lock validity |
| loop_wait | `failover_time / 3` | HA cycle interval (3 renewals per TTL) |
| retry_timeout | `failover_time / 3` | DCS operation timeout |

The 3:1 ratio ensures the leader has 3 chances to renew before TTL expires, tolerating transient failures.

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
