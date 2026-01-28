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
  # endpoint_url: http://localhost:8000  # optional for DynamoDB Local
```

## Patroni Basics (context)

```yaml
scope: my-cluster
name: node-1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.10:8008

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.10:5432
  data_dir: /var/lib/postgresql/16/main
  bin_dir: /usr/lib/postgresql/16/bin
```

## Common Environment Variables

These are typically used by bootstrap scripts or templates:

- `AWS_REGION` – region used by the AWS SDK
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` – optional; prefer IAM roles in production
- `DYNAMODB_TABLE` – used by templates to fill `dynamodb.table_name`
- `PATRONI_SCOPE` – cluster name (used as `cluster_name` in DynamoDB)
- `PATRONI_NODE_NAME` – node identifier in the cluster
- `PATRONI_CONNECT_ADDRESS` – advertised address for REST API / Postgres
- `POSTGRES_PASSWORD`, `REPLICATOR_PASSWORD` – if templating auth into Patroni config

## Runtime Considerations

- **TTL behavior**: leader/member keys expire via TTL; ensure clocks are in sync.
- **Retry settings**: `loop_wait`, `retry_timeout`, and `ttl` should be tuned for
  your network latency. Faster loops increase DynamoDB write volume.
- **Endpoint URLs**: use `endpoint_url` only for local testing.

## Example: envsubst template usage

```bash
export AWS_REGION=us-east-1
export DYNAMODB_TABLE=patroni-dynamodb
export PATRONI_SCOPE=prod-db
export PATRONI_NODE_NAME=db-1
export PATRONI_CONNECT_ADDRESS=10.0.0.10

envsubst < /etc/patroni/patroni.yml.template > /etc/patroni/patroni.yml
```
