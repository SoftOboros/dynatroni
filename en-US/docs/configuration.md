<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Configuration & Environment

Dynatroni is configured inside your Patroni YAML under the `dynamodb:` key.

## Dynatroni Block

```yaml
dynamodb:
  region: us-east-1           # Optional: defaults to ca-central-1, or AWS SDK region resolution
  table_name: patroni-dynamodb # Optional: defaults to softoboros-patroni
  failover_time: 60           # Optional: defaults to 60 (single dial for cost vs responsiveness)
  # endpoint_url: http://localhost:8000  # optional for DynamoDB Local
```

**Defaults and AWS SDK region resolution:**
- `region`: Defaults to `ca-central-1`. If omitted, also checks `AWS_REGION` / `AWS_DEFAULT_REGION` environment variables, then EC2 instance metadata (IMDS).
- `table_name`: Defaults to `softoboros-patroni`.
- `failover_time`: Defaults to 60 seconds. Minimum allowed is 15 seconds.

## Failover Time: The Single Dial

The `failover_time` parameter controls the cost vs responsiveness tradeoff. All
timing parameters are derived from this single value:

| failover_time | TTL | loop_wait | retry_timeout | DynamoDB ops/min | Use case |
|---------------|-----|-----------|---------------|------------------|----------|
| 15s | 15s | 5s | 5s | ~24 | Fast failover, higher cost |
| 60s (default) | 60s | 20s | 20s | ~6 | Balanced |
| 180s | 180s | 60s | 60s | ~2 | Cost optimised, slower failover |

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
  --name /softoboros/dumbo/patroni/failover_time \
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

The Dumbo AMI reads configuration from AWS Systems Manager Parameter Store.
All parameters use the `/softoboros/dumbo/` prefix.

### Required Parameters

These must exist before launching the AMI:

| Parameter | Type | Description |
|-----------|------|-------------|
| `/softoboros/dumbo/db/password` | SecureString | PostgreSQL superuser password |
| `/softoboros/dumbo/db/replicator_password` | SecureString | Streaming replication user password |

### Optional Parameters

These have sensible defaults and can be omitted:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `/softoboros/dumbo/db/user` | String | `postgres` | PostgreSQL superuser name |
| `/softoboros/dumbo/db/db` | String | `softoboros` | Default database name |
| `/softoboros/dumbo/pg/shared_buffers` | String | `256MB` | PostgreSQL shared_buffers |
| `/softoboros/dumbo/pg/effective_cache_size` | String | `768MB` | PostgreSQL effective_cache_size |
| `/softoboros/dumbo/pg/work_mem` | String | `8MB` | PostgreSQL work_mem |
| `/softoboros/dumbo/pg/maintenance_work_mem` | String | `64MB` | PostgreSQL maintenance_work_mem |
| `/softoboros/dumbo/patroni/dynamodb_table` | String | `softoboros-patroni` | DynamoDB table for leader election |
| `/softoboros/dumbo/patroni/failover_time` | String | `60` | Failover time in seconds (see below) |
| `/softoboros/dumbo/cloudmap_service_id` | String | (none) | Cloud Map service ID for DNS registration |

### Creating Required Parameters

```bash
# Create the required secrets
aws ssm put-parameter \
  --name /softoboros/dumbo/db/password \
  --type SecureString \
  --value "your-secure-password"

aws ssm put-parameter \
  --name /softoboros/dumbo/db/replicator_password \
  --type SecureString \
  --value "your-replicator-password"
```

### PostgreSQL Memory Tuning

The default memory settings are sized for t4g.small (2GB RAM). Adjust for your instance size:

| Instance | shared_buffers | effective_cache_size | work_mem | maintenance_work_mem |
|----------|----------------|----------------------|----------|----------------------|
| t4g.small (2GB) | 256MB | 768MB | 8MB | 64MB |
| t4g.medium (4GB) | 512MB | 1536MB | 16MB | 128MB |
| t4g.large (8GB) | 1GB | 3GB | 32MB | 256MB |

## Common Environment Variables

These are typically used by bootstrap scripts or templates:

- `AWS_REGION` – region used by the AWS SDK
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` – optional; prefer IAM roles in production
- `DYNAMODB_TABLE` – used by templates to fill `dynamodb.table_name`
- `PATRONI_SCOPE` – cluster name (used as `cluster_name` in DynamoDB)
- `PATRONI_NODE_NAME` – node identifier in the cluster
- `PATRONI_CONNECT_ADDRESS` – advertised address for REST API / Postgres
- `POSTGRES_PASSWORD`, `REPLICATOR_PASSWORD` – if templating auth into Patroni config

## Cold Boot Environment Variables

These control the cold boot leader election behaviour. Set via EC2 user data or
environment variable (env var takes precedence):

| Variable | Default | Description |
|----------|---------|-------------|
| `DUMBO_COLD_BOOT_TIMEOUT` | 300 | Max seconds to wait for last leader's AZ |
| `DUMBO_FORCE_LEADER_PROMOTION` | false | Skip cold boot check entirely (risk of data loss) |
| `DUMBO_VOLUME_ID` | (auto-detect) | EBS volume ID for Docker mode volume matching |

**Example EC2 user data:**
```bash
#!/bin/bash
DUMBO_COLD_BOOT_TIMEOUT=600
```

**Setting via SSM:**
```bash
aws ssm put-parameter \
  --name /softoboros/dumbo/cold_boot_timeout \
  --value "600" \
  --type String \
  --overwrite
```

See [Multi-AZ & Cold Start](multi-az-and-cold-start.md) for full cold boot behaviour.

## VPC Network Access

The default `pg_hba.conf` allows connections from the VPC CIDR `10.20.0.0/16`:

```
host    replication     replicator      10.20.0.0/16            scram-sha-256
host    all             all             10.20.0.0/16            scram-sha-256
```

Modify `/etc/postgresql/16/main/pg_hba.conf` for different VPC CIDRs.

## Runtime Considerations

- **TTL behaviour**: Different key types have different TTL multipliers:
  - `leader`: TTL = `failover_time` (lock validity window)
  - `members/*`, `status`: TTL = `failover_time * 2` (survive missed heartbeats)
  - `config`, `sync`, `failover`, `history`, `initialize`, `failsafe`: No TTL (persistent)

  Ensure clocks are in sync (NTP). DynamoDB TTL cleanup is eventually consistent; expired items may linger up to 48 hours but are filtered in application reads.
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
