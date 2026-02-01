<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Operations & Troubleshooting

## Patroni Commands

```bash
# Show cluster members
patronictl -c /etc/patroni/patroni.yml list

# Planned switchover
patronictl -c /etc/patroni/patroni.yml switchover

# Forced failover
patronictl -c /etc/patroni/patroni.yml failover --force

# Reinitialize a replica
patronictl -c /etc/patroni/patroni.yml reinit <member-name>
```

## Systemd / Journald

```bash
systemctl status patroni
systemctl restart patroni
journalctl -u patroni -f
```

## Health Endpoints

```bash
curl -s http://localhost:8008/health
curl -s http://localhost:8008/primary
```

## DynamoDB Debugging

```bash
aws dynamodb query \
  --table-name patroni-dynamodb \
  --key-condition-expression "cluster_name = :cn" \
  --expression-attribute-values '{":cn": {"S": "my-cluster"}}'
```

## Image Operational Safeguards

The Dumbo AMI includes several safeguards for production stability:

### Cold Boot Leader Election

When the entire cluster is shut down and restarted, a **cold boot check** runs
before Patroni starts to prevent a stale replica from becoming leader:

1. Checks DynamoDB for a `last_leader` record (written whenever a node becomes primary)
2. If in the same AZ as the last leader, proceeds immediately as leader candidate
3. If in a different AZ, waits for the last leader's AZ to start first
4. Falls back to **checkpoint timestamp election** if no `last_leader` record exists

**Timeout**: Default 5 minutes, configurable via `DUMBO_COLD_BOOT_TIMEOUT` env var
or EC2 user data (in seconds). Must be less than `TimeoutStartSec` in patroni.service.

**Checkpoint timestamp election**: Each node registers its PostgreSQL checkpoint
timestamp; the node with the newest data becomes leader.

**Emergency override**: Set `DUMBO_FORCE_LEADER_PROMOTION=true` in instance
user_data to bypass the cold boot check (risk of data loss).

### Disabled Background Services

The AMI disables services that interfere with database performance or immutable
infrastructure:

| Service | Reason |
|---------|--------|
| `apt-daily-upgrade.timer` | Immutable AMIs; no live patching |
| `apt-daily.timer` | Immutable AMIs; no live patching |
| `man-db.timer` | Unnecessary on servers |
| `e2scrub_all.timer` | EBS handles integrity; ext4 scrubbing wastes IOPS |

### Tuned Services

| Service | Configuration | Reason |
|---------|--------------|--------|
| `fstrim.timer` | 4x daily (00:00, 06:00, 12:00, 18:00) | Spread TRIM load vs weekly spike |
| `postgresql@16-main` | Disabled | Patroni manages PostgreSQL lifecycle |
| `pgbouncer` | Disabled (default) | Managed by `dumbo-pgbouncer.service` |

### SSM Agent

AWS Systems Manager Agent is installed and enabled for:
- Secure shell access without SSH keys
- Parameter Store integration
- Run Command for fleet operations

### Syslog Forwarding

The `dumbo-syslog.service` configures rsyslog to forward logs to a central
aggregator. Configure the destination via `/etc/rsyslog.d/00-softoboros-common.conf`.

## Failover Time Tuning

Adjust the `failover_time` SSM parameter to balance cost and responsiveness:

```bash
# Check current setting
aws ssm get-parameter --name /softoboros/patroni/failover_time

# Update (takes effect on next Patroni restart)
aws ssm put-parameter \
  --name /softoboros/patroni/failover_time \
  --value "30" \
  --type String \
  --overwrite
```

See [Configuration](configuration.md) for the failover_time derivation table.

## Common Issues

- **Access denied**: confirm IAM permissions for DynamoDB actions.
- **Wrong region**: ensure `AWS_REGION` or `dynamodb.region` matches the table's region.
- **Leader churn**: increase `failover_time` if the cluster is unstable (default: 60s).
- **Clock drift**: TTL logic assumes roughly synchronized clocks.
- **Stuck leader**: see [Break‑glass promotion](break-glass.md).
- **Cold boot stall**: check `/var/log/syslog` for `[cold-boot-check]` messages;
  increase `DUMBO_COLD_BOOT_TIMEOUT` (default 300s) in user_data if the last leader's
  AZ is slow to start; use `DUMBO_FORCE_LEADER_PROMOTION=true` only as last resort.
- **Testing mismatch**: etcd‑based local tests don't validate Dynatroni. Use DynamoDB Local or a dev table when possible.
