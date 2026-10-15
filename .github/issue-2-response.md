Thanks for the report. We reproduced this failure and traced it to Dynatroni's
installation: version 0.1.0 declared a Python entry point, but Patroni discovers
DCS backends by scanning modules inside `patroni.dcs`. The package could install
successfully while DynamoDB remained unavailable. The quickstart incorrectly
said that the entry point was sufficient.

A fix is prepared on the [v0.1.1 branch](https://github.com/SoftOboros/dynatroni/tree/v0.1.1).
It installs a small `patroni.dcs.dynamodb` adapter that imports the existing
implementation. Manual copying into Patroni's package is no longer needed.
The package now requires Patroni 3.3.0 or later to match the APIs it uses.

Version 0.1.1 has not been published to PyPI yet. To try the branch in your
existing environment before release:

```bash
/opt/pg/18.4/venv/bin/python -m pip install --upgrade \
  'git+https://github.com/SoftOboros/dynatroni.git@v0.1.1'
```

After 0.1.1 is published, the PyPI installation command will be:

```bash
/opt/pg/18.4/venv/bin/python -m pip install --upgrade 'dynatroni>=0.1.1'
```

Verify discovery using the same interpreter before restarting Patroni:

```bash
/opt/pg/18.4/venv/bin/python -I - <<'PY'
from patroni.dcs import iter_dcs_classes

backends = dict(iter_dcs_classes({"dynamodb": {}}))
assert "dynamodb" in backends, "DynamoDB backend is unavailable"
print(backends["dynamodb"])
PY
```

Your top-level `dynamodb:` section matches the expected configuration shape.
This discovery check does not contact AWS or start PostgreSQL. Once it passes,
start Patroni normally and check any subsequent AWS or PostgreSQL errors
separately. If discovery still fails, please share the output of:

```bash
/opt/pg/18.4/venv/bin/python -m pip show patroni dynatroni boto3
/opt/pg/18.4/venv/bin/python -c \
  'from patroni.dcs.dynamodb import DynamoDB; print(DynamoDB)'
```

We verified the fixed wheel on Python 3.14 and the source distribution on Python
3.12 with Patroni 4.1.5, plus the minimum Patroni 3.3.0 on Python 3.11. These are
installation, discovery, and construction checks with mocked AWS clients;
live cluster behavior has not been validated against your environment.
