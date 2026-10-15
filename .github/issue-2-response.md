Thanks for the report. We reproduced this failure and traced it to Dynatroni's
installation: version 0.1.0 declared a Python entry point, but Patroni discovers
DCS backends by scanning modules inside `patroni.dcs`. The package could install
successfully while DynamoDB remained unavailable. The quickstart incorrectly
said that the entry point was sufficient.

**[Dynatroni 0.1.1 is now available on PyPI](https://pypi.org/project/dynatroni/0.1.1/).**
It installs a small `patroni.dcs.dynamodb` adapter that imports the existing
implementation. This replaces the manual-copy workaround above.
The package now requires Patroni 3.3.0 or later to match the APIs it uses.

Upgrade using the same virtual environment shown in your traceback:

```bash
/opt/pg/18.4/venv/bin/python -m pip install --upgrade 'dynatroni==0.1.1'
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

We verified an uncached installation of the published PyPI wheel in a fresh
Python 3.14.4 environment with Patroni 4.1.5. Backend discovery, DCS construction
with mocked AWS clients, and `pip check` passed; the downloaded wheel's SHA-256
matched PyPI's record. All seven CI jobs also passed, covering wheel and source
installations on Python 3.9, 3.12, and 3.14, including minimum Patroni 3.3.0.

See the updated [installation guide](https://github.com/SoftOboros/dynatroni/blob/pypi-0.1.1/docs/install.md).
These checks do not establish live cluster behavior in your environment.
Please let us know whether Patroni starts successfully after the upgrade;
we are leaving this issue open for your confirmation.
