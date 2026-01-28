<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Install & Quickstart

## Install the Python package

```bash
pip install dynatroni
```

Dynatroni is a Patroni DCS backend and is discovered via entry points. No
manual `patroni.dcs` copying is required when installed from PyPI.

## Minimal Patroni config

```yaml
scope: my-cluster
name: node-1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.10:8008

dynamodb:
  region: us-east-1
  table_name: patroni-dynamodb

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.10:5432
  data_dir: /var/lib/postgresql/16/main
  bin_dir: /usr/lib/postgresql/16/bin
```

## Start Patroni

```bash
patroni /etc/patroni/patroni.yml
```

## Next

- [DynamoDB setup](dynamodb.md)
- [Configuration & environment](configuration.md)
