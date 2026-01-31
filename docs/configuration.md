<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Configuration & Environment

Dynatroni is configured inside your Patroni YAML under the `dynamodb:` key.

## Dynatroni Block

```yaml
dynamodb:
  region: us-east-1
  table_name: patroni-dynamodb
  failover_time: 60  # Single dial for cost vs responsiveness (default: 60)
  # endpoint_url: http://localhost:8000  # optional for DynamoDB Local
```

## Failover Time: The Single Dial

The `failover_time` parameter controls the cost vs responsiveness tradeoff. All
timing parameters are derived from this single value:

| failover_time | TTL | loop_wait | retry_timeout | DynamoDB ops/min | Use case |
|---------------|-----|-----------|---------------|------------------|----------|
| 15s | 15s | 5s | 5s | ~24 | Fast failover, higher cost |
| 60s (default) | 60s | 20s | 20s | ~6 | Balanced |
| 180s | 180s | 60s | 60s | ~2 | Cost optimized, slower failover |

**Derived timing formulas:**
- `ttl` = failover_time (leader lock validity window)
- `loop_wait` = failover_time / 3 (Patroni HA cycle interval)
- `retry_timeout` = failover_time / 3 (DCS operation timeout)

The minimum allowed `failover_time` is 15 seconds for safety.

### Setting via SSM Parameter Store

For the Dumbo AMI, `failover_time` is read from SSM at boot:

```bash
# Set failover_time for all cluster nodes
aws ssm put-parameter \
  --name /softoboros/patroni/failover_time \
  --value "60" \
  --type String \
  --overwrite
```

## Patroni Basics (context)

```yaml
scope: my-cluster
name: node-1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.10:8008

bootstrap:
  dcs:
    # These are derived from failover_time by dumbo-patroni-configure.sh
    ttl: 60
    loop_wait: 20
    retry_timeout: 20
    maximum_lag_on_failover: 1048576  # 1MB lag threshold

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.10:5432
  data_dir: /data/pgdata/16/main
  bin_dir: /usr/lib/postgresql/16/bin
```

## SSM Parameters (Dumbo AMI)

The Dumbo AMI reads configuration from AWS Systems Manager Parameter Store:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `/softoboros/patroni/dynamodb_table` | DynamoDB table name | `softoboros-patroni` |
| `/softoboros/patroni/failover_time` | Failover time in seconds | `60` |
| `/softoboros/postgres/replicator_password` | Replication user password | (required) |

## Common Environment Variables

These are typically used by bootstrap scripts or templates:

- `AWS_REGION` – region used by the AWS SDK
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` – optional; prefer IAM roles in production
- `DYNAMODB_TABLE` – used by templates to fill `dynamodb.table_name`
- `PATRONI_SCOPE` – cluster name (used as `cluster_name` in DynamoDB)
- `PATRONI_NODE_NAME` – node identifier in the cluster
- `PATRONI_CONNECT_ADDRESS` – advertised address for REST API / Postgres
- `POSTGRES_PASSWORD`, `REPLICATOR_PASSWORD` – if templating auth into Patroni config

## VPC Network Access

The default `pg_hba.conf` allows connections from the VPC CIDR `10.20.0.0/16`:

```
host    replication     replicator      10.20.0.0/16            scram-sha-256
host    all             all             10.20.0.0/16            scram-sha-256
```

Modify `/etc/postgresql/16/main/pg_hba.conf` for different VPC CIDRs.

## Runtime Considerations

- **TTL behavior**: leader/member keys expire via TTL; ensure clocks are in sync.
- **Failover time tuning**: use `failover_time` as the single dial; individual
  `ttl`, `loop_wait`, and `retry_timeout` values are derived automatically.
- **Endpoint URLs**: use `endpoint_url` only for local testing with DynamoDB Local.
- **Cost estimation**: DynamoDB ops ≈ 60 / failover_time per minute per node.

## Example: envsubst template usage

```bash
export AWS_REGION=us-east-1
export DYNAMODB_TABLE=patroni-dynamodb
export PATRONI_SCOPE=prod-db
export PATRONI_NODE_NAME=db-1
export PATRONI_CONNECT_ADDRESS=10.0.0.10

envsubst < /etc/patroni/patroni.yml.template > /etc/patroni/patroni.yml
```
