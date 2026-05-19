```markdown
<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Break-Glass Promotion (Emergency)

Use this only when normal failover is blocked and you accept the risk of data
loss or split-brain if run incorrectly.

## Preferred: Patroni-Managed Failover

On a healthy node, run:

```bash
patronictl -c /etc/patroni/patroni.yml list
patronictl -c /etc/patroni/patroni.yml failover --force
```

If the cluster is healthy, use a controlled switchover instead:

```bash
patronictl -c /etc/patroni/patroni.yml switchover
```

## Last Resort: Clear the Leader Lock

If the leader record is stuck in DynamoDB and the old leader is confirmed down,
clear the leader key **for this cluster only**, then retry the failover.

**Example (replace placeholders):**

```bash
aws dynamodb delete-item \
  --table-name patroni-dynamodb \
  --key '{"cluster_name": {"S": "my-cluster"}, "key": {"S": "leader"}}'
```

## Safety Checks

- Ensure the old leader is **stopped** and cannot rejoin as primary.
- Confirm the candidate replica is reasonably up to date.
- After promotion, re-add old nodes as replicas and validate replication.

## Optional Boot Override

If you implement a cold-boot guard script, provide a manual override (for
example, a `DYNATRONI_BREAK_GLASS=1` environment variable) to bypass the guard in
emergencies. Document this in your internal runbook.
```
