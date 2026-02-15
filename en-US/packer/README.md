```markdown
<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="300">
</p>

# Dynatroni Packer Build

This folder contains Packer builds for Patroni + Dynatroni AMIs.

## Available Builds

| Template | Description |
|----------|-------------|
| `dynatroni-debian12-arm64.pkr.hcl` | Minimal Patroni + Dynatroni (no PostgreSQL) |
| `softoboros-dumbo-debian12-arm64.pkr.hcl` | Full stack: PostgreSQL 16 + pgvector + pgbouncer + Patroni HA |

## Dynatroni Minimal Build

### Required Env Vars

Set these before running `packer build`:

- `DYNATRONI_AWS_REGION`
- `DYNATRONI_SOURCE_AMI`
- `DYNATRONI_INSTANCE_TYPE`
- `DYNATRONI_SSH_USERNAME`
- `DYNATRONI_AMI_NAME`
- `DYNATRONI_AMI_DESCRIPTION`
- `DYNATRONI_SUBNET_ID`
- `DYNATRONI_SECURITY_GROUP_ID`
- `DYNATRONI_IAM_INSTANCE_PROFILE`
- `DYNATRONI_AMI_TAGS_JSON` (optional, JSON map)

### Notes

- The service is installed but not enabled by the template.
- `dynatroni-configure.sh` uses env vars at boot to render `/etc/patroni/patroni.yml`.
- This template does not install PostgreSQL; add that to the build for a complete node.

## Dumbo Full Stack Build

The Dumbo build creates a production-ready PostgreSQL HA node with:

- PostgreSQL 16 from PGDG
- pgvector extension for embeddings
- pgbouncer connection pooler
- Patroni HA with DynamoDB DCS (Dynatroni)
- AWS SSM Agent for secure management

### Operational Safeguards

The Dumbo AMI includes hardening for production stability:

**Disabled services** (immutable infrastructure):
- `apt-daily-upgrade.timer`, `apt-daily.timer` – no live patching
- `man-db.timer` – unnecessary on servers
- `e2scrub_all.timer` – EBS handles integrity

**Tuned services**:
- `fstrim.timer` – 4x daily instead of weekly (spread IOPS load)
- `postgresql @16-main` – disabled; Patroni manages PostgreSQL
- `pgbouncer` – managed by `dumbo-pgbouncer.service`

**Cold boot protection**:
- `dumbo-cold-boot-check.sh` prevents stale replicas from becoming leader
- Uses checkpoint timestamp election when no prior leader record exists
- Override with `DUMBO_FORCE_LEADER_PROMOTION=true` in user_data

### Configuration via SSM

The Dumbo AMI reads configuration from Parameter Store at boot:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `/softoboros/patroni/dynamodb_table` | DynamoDB table name | `softoboros-patroni` |
| `/softoboros/patroni/failover_time` | Failover time (15-180s) | `60` |
| `/softoboros/postgres/replicator_password` | Replication password | (required) |

### Failover Time

The `failover_time` parameter is the single dial for cost vs responsiveness:

```
15s  → Fast failover, ~24 DynamoDB ops/min
60s  → Balanced (default), ~6 ops/min
180s → Cost optimized, ~2 ops/min
```

All timing values (ttl, loop_wait, retry_timeout) are derived automatically.

### VPC Network

Default `pg_hba.conf` allows connections from `10.20.0.0/16`. Modify
`/etc/postgresql/16/main/pg_hba.conf` for different VPC CIDRs.

### User Data Options

Instance user_data supports key=value configuration:

```
# Emergency: force leader promotion (risk of data loss)
DUMBO_FORCE_LEADER_PROMOTION=true
```
```
