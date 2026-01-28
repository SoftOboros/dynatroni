<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Multi‑AZ & Cold Start

## Multi‑AZ Considerations

- **DynamoDB is regional** and highly available; it can be used as the
  cluster arbiter across AZs.
- **Latency matters**: cross‑AZ latency influences `loop_wait`, `ttl`, and
  `retry_timeout`. Use conservative values when AZs are far apart.
- **Failure domains**: run at least two nodes in different AZs to tolerate
  single‑AZ failures.
- **Network partitions**: if the network is unstable, a short `ttl` can cause
  rapid leader churn. Prefer stability over aggressiveness.

## Cold Start (All Nodes Down)

When the entire cluster is stopped, the previous leader lock may still exist
until TTL expiry. Recommended sequence:

1. **Pick a bootstrap leader** (the most up‑to‑date replica if possible).
2. **Start the bootstrap leader alone** and wait for it to acquire leadership.
3. **Start remaining nodes** and allow them to follow.

If you cannot determine the freshest replica, avoid forcing promotion until you
confirm data safety.

### Optional Guardrails

- **Cold‑boot guard**: implement a small pre‑start script to ensure only one
  node attempts leadership on cold boot.
- **Pause others**: start secondaries with `nofailover` or `pause` tags, then
  remove once the leader is established.

## When to Use “Break Glass”

See [Break‑glass promotion](break-glass.md) for emergency promotion options.
