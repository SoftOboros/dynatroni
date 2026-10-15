"""Run with python -I against an installed wheel or source distribution.

Discovery must work without importing dynatroni first, modifying sys.path,
copying files, or contacting AWS. An editable install is not sufficient.
"""

from importlib.metadata import distribution
import unittest
from unittest.mock import patch

import patroni.dcs


class InstalledDiscoveryTests(unittest.TestCase):
    def test_discovery_and_factory(self):
        # Patroni must find the adapter before dynatroni is explicitly imported.
        backends = dict(patroni.dcs.iter_dcs_classes({"dynamodb": {}}))
        self.assertIn("dynamodb", backends)

        from dynatroni.dynamodb import DynamoDB

        self.assertIs(backends["dynamodb"], DynamoDB)
        config = {
            "scope": "discovery-test",
            "name": "node-1",
            "ttl": 30,
            "loop_wait": 10,
            "retry_timeout": 10,
            "dynamodb": {"region": "eu-central-1", "table_name": "test"},
        }
        with patch("boto3.client") as client, patch("boto3.resource") as resource:
            dcs = patroni.dcs.get_dcs(config)

        self.assertIs(type(dcs), DynamoDB)
        self.assertEqual(dcs._cluster_name, "discovery-test")
        client.assert_called_once_with("dynamodb", region_name="eu-central-1")
        resource.assert_called_once_with("dynamodb", region_name="eu-central-1")
        resource.return_value.Table.assert_called_once_with("test")

    def test_package_ownership(self):
        import dynatroni

        package = distribution("dynatroni")
        self.assertEqual(package.version, dynatroni.__version__)
        files = {str(path) for path in package.files}
        self.assertEqual(
            {path for path in files if path.startswith("patroni/") and "__pycache__" not in path},
            {"patroni/dcs/dynamodb.py"},
        )
        # The adapter must not replace any file owned by Patroni.
        self.assertFalse(files.intersection(str(path) for path in distribution("patroni").files))


if __name__ == "__main__":
    unittest.main(verbosity=2)
