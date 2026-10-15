<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Install & Quickstart

## Install the Python package

Use the Python interpreter from the virtual environment that runs Patroni:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade 'dynatroni>=0.1.1' 'patroni[psycopg3]'
```

Version 0.1.1 is the next release. Until it is published, install from a checkout
containing this fix with `python -m pip install . 'patroni[psycopg3]'` in the
activated environment. The Patroni extra installs a PostgreSQL driver; keep an
existing supported driver if one is already installed.

Dynatroni requires Patroni 3.3.0 or later. Earlier versions lack DCS APIs used by
the implementation.

Patroni discovers DCS implementations by scanning its `patroni.dcs` package.
Dynatroni installs a small `patroni.dcs.dynamodb` adapter that imports the
implementation from `dynatroni.dynamodb`. Normal wheel and source installations
include this adapter automatically. Python entry points are not used for this
discovery. Use a normal installation (`python -m pip install .`) when developing
from source; editable installations do not reliably expose the adapter to
Patroni's directory scan.

## Verify discovery

Run this with the same interpreter that runs Patroni, before starting the service:

```bash
python -I - <<'PY'
from patroni.dcs import iter_dcs_classes

backends = dict(iter_dcs_classes({"dynamodb": {}}))
assert "dynamodb" in backends, "DynamoDB backend is unavailable"
print(backends["dynamodb"])
PY
```

This checks backend discovery without contacting AWS or starting PostgreSQL.
It does not validate credentials, table access, or cluster operation.

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

Create the table and configure AWS credentials with the required permissions
first; see [DynamoDB setup](dynamodb.md).

```bash
patroni /etc/patroni/patroni.yml
```

## Troubleshoot a missing backend

If Patroni reports `Can not find suitable configuration of distributed
configuration store` and omits `dynamodb` from the available implementations,
check package versions and import the backend with the service's interpreter:

```bash
python -m pip show patroni dynatroni boto3
python -c 'from patroni.dcs.dynamodb import DynamoDB; print(DynamoDB)'
```

For example, issue #2 uses `/opt/pg/18.4/venv/bin/python`. Substitute that
absolute path for `python` in these checks and installation commands. A direct
import exposes dependency or compatibility errors that Patroni may suppress
during discovery. Installing into a different environment does not repair the
service's installation.

Dynatroni 0.1.0 declared an entry point without installing the adapter, so a
successful package installation could still leave DynamoDB undiscoverable.
Upgrade to 0.1.1 or install the fixed source checkout. If an older installation
used a manually copied `patroni/dcs/dynamodb.py`, the normal installation replaces
it with the adapter. Keep Patroni and Dynatroni in the same virtual environment;
use pip to manage this file going forward.

## Verify a source change

```bash
python -m pip install . 'patroni[psycopg3]'
python -I tests/test_installed_discovery.py
```

CI builds and installs both a wheel and a source distribution, checks discovery
and DCS construction with AWS clients mocked, and verifies that uninstalling
Dynatroni preserves Patroni's files.

## Next

- [DynamoDB setup](dynamodb.md)
- [Configuration & environment](configuration.md)
