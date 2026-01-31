<p align="center">
  <img src="dynatroni.png" alt="Dynatroni" width="360">
</p>

# Dynatroni (Patroni DynamoDB DCS)

Dynatroni is a DynamoDB-based Distributed Configuration Store (DCS) backend for
Patroni PostgreSQL HA.

## Features

- **DynamoDB as arbiter**: leader election via DynamoDB conditional writes
- **No quorum requirement**: a single surviving node can operate
- **AWS-native**: IAM auth, managed service
- **Cost-effective**: pay‑per‑request pricing for small clusters
- **Highly available**: DynamoDB’s built‑in multi‑AZ replication

## Docs

- [Docs index](docs/README.md)
- [Install & quickstart](docs/install.md)
- [DynamoDB setup](docs/dynamodb.md)
- [Configuration & environment](docs/configuration.md)
- [Multi‑AZ & cold start](docs/multi-az-and-cold-start.md)
- [Break‑glass promotion](docs/break-glass.md)
- [Operations & troubleshooting](docs/operations.md)

## Installation

```bash
pip install dynatroni
```

## DynamoDB Table Setup

Create a DynamoDB table with:
- Partition Key: `cluster_name` (String)
- Sort Key: `key` (String)
- TTL attribute: `ttl`

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

aws dynamodb update-time-to-live \
  --table-name patroni-dynamodb \
  --time-to-live-specification "Enabled=true,AttributeName=ttl"
```

## Patroni Configuration

In your `patroni.yml`:

```yaml
scope: my-cluster
name: node1

dynamodb:
  region: us-east-1
  table_name: patroni-dynamodb
  # Single dial for cost vs responsiveness tradeoff:
  #   15s  = fast failover, ~24 DynamoDB ops/min
  #   60s  = balanced (default), ~6 ops/min
  #   180s = cost optimized, ~2 ops/min
  failover_time: 60
  # Optional: for local testing with DynamoDB Local
  # endpoint_url: http://localhost:8000

# Timing values are derived from failover_time:
#   ttl = failover_time
#   loop_wait = failover_time / 3
#   retry_timeout = failover_time / 3

# ... rest of patroni config
```

## IAM Permissions

The EC2 instance role needs:

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

## How It Works

1. **Leader Election**: DynamoDB conditional writes implement atomic leader locks
2. **TTL-based Locking**: leader key expires if not renewed
3. **Member Registration**: each node registers itself with a TTL
4. **Cluster State**: config, sync state, and failover settings stored as JSON

## License

MIT
