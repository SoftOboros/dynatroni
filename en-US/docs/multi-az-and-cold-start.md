<p align="centre">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Multi-AZ & Cold Start

## Multi-AZ Considerations

- **DynamoDB is regional** and highly available; it can be used as the
  cluster arbiter across AZs.
- **Latency matters**: cross-AZ latency influences `loop_wait`, `ttl`, and
  `retry_timeout`. Use conservative values when AZs are far apart.
- **Failure domains**: run at least two nodes in different AZs to tolerate
  single-AZ failures.
- **Network partitions**: if the network is unstable, a short `ttl` can cause
  rapid leader churn. Prefer stability over aggressiveness.

## Cold Start (All Nodes Down)

When the entire cluster is stopped and all nodes restart simultaneously, a
**cold boot check** prevents a stale replica from becoming leader.

### Automatic Cold Boot Protection (Dumbo AMI)

The Dumbo AMI implements automatic cold boot protection via the
`dumbo-cold-boot-check.sh` script (runs as `ExecStartPre` before Patroni):

#### Last Leader Tracking

Whenever a node becomes primary (on `on_start` or `on_role_change`), Patroni
writes a `last_leader` record to DynamoDB containing:
- Instance ID
- Availability Zone (with suffix like `a`, `b`, `c`)
- EBS volume ID
- Timestamp

This record persists until a new leader is elected (no TTL).

#### Cold Boot Election Logic

On cold boot, each node:

1. **Checks DynamoDB for `last_leader` record**
2. **AWS mode (IMDS available)**: Uses AZ-based preference
   - If in the same AZ as last leader → proceeds immediately as leader candidate
   - If in different AZ → waits for last leader's AZ to come up first
3. **Docker mode (no IMDS)**: Uses volume_id matching
   - If same volume as last leader → proceeds immediately
   - If different volume → waits for last leader
4. **Fallback election**: If no `last_leader` record exists, uses PostgreSQL
   checkpoint timestamp to elect the node with the newest data

#### Configuration

| Setting | Source | Default | Description |
|---------|--------|---------|-------------|
| `DUMBO_COLD_BOOT_TIMEOUT` | User data or env var | 300 (5 min) | Maximum wait time for leader AZ |
| `DUMBO_FORCE_LEADER_PROMOTION` | User data or env var | false | Skip cold boot check entirely |

**Example user data:**
```bash
#!/bin/bash
DUMBO_COLD_BOOT_TIMEOUT=600    # Wait up to 10 minutes
```

**Emergency override:**
```bash
#!/bin/bash
DUMBO_FORCE_LEADER_PROMOTION=true  # Skip cold boot check (risk of data loss)
```

#### Systemd Timeout

The cold boot check can take up to `DUMBO_COLD_BOOT_TIMEOUT` seconds. The
`patroni.service` unit has `TimeoutStartSec=360` to accommodate this. Adjust
the systemd timeout if using a longer cold boot timeout.

### Manual Cold Start Procedure

If not using the Dumbo AMI or for disaster recovery:

1. **Pick a bootstrap leader** (the most up-to-date replica if possible).
2. **Start the bootstrap leader alone** and wait for it to acquire leadership.
3. **Start remaining nodes** and allow them to follow.

If you cannot determine the freshest replica, avoid forcing promotion until you
confirm data safety.

## When to Use "Break Glass"

See [Break-glass promotion](break-glass.md) for emergency promotion options.
