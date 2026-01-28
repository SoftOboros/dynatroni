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

## Common Issues

- **Access denied**: confirm IAM permissions for DynamoDB actions.
- **Wrong region**: ensure `AWS_REGION` or `dynamodb.region` matches the table’s region.
- **Leader churn**: increase `ttl` or `loop_wait` if the cluster is unstable.
- **Clock drift**: TTL logic assumes roughly synchronized clocks.
- **Stuck leader**: see [Break‑glass promotion](break-glass.md).
- **Testing mismatch**: etcd‑based local tests don’t validate Dynatroni. Use DynamoDB Local or a dev table when possible.
