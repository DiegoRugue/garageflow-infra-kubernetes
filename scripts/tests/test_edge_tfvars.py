import copy
import importlib
import io
import json
import sys
import unittest
from contextlib import redirect_stderr
from unittest.mock import patch

from test_infra_contract import ROOT, manifest, producer_outputs, trusted_temp_directory
from test_ingress_contract_v2 import ingress_v2

sys.path.insert(0, str(ROOT / "scripts"))


class EdgeVariablesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = importlib.import_module("edge_tfvars")

    def build(self, **changes):
        arguments = dict(component="edge", platform=manifest(), ingress=ingress_v2(),
                         serverless=manifest("serverless", outputs=producer_outputs()["serverless"]),
                         environment="homologation", account="123456789012", owner="garageflow", expires_on="2026-09-11")
        arguments.update(changes)
        return self.module.build_variables(**arguments)

    def test_builds_only_required_contracts(self):
        result = self.build()
        self.assertEqual("2.0", result["ingress_contract"]["schemaVersion"])
        result = self.build(component="ingress", ingress=None, serverless=None)
        self.assertEqual({"environment", "owner", "expires_on", "platform_contract"}, set(result))

    def test_rejects_account_environment_version_and_missing_metadata(self):
        for changes in [dict(account="999999999999"), dict(account="bad"), dict(environment="production"),
                        dict(ingress=None), dict(serverless=None), dict(component="unknown"),
                        dict(owner=" "), dict(expires_on="2026-02-30")]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.build(**changes)
        for producer, field in [("platform", "jwtSecretArn"), ("ingress", "listenerArn"), ("serverless", "requestAuthorizerAliasArn")]:
            document = {"platform": manifest(), "ingress": ingress_v2(), "serverless": manifest("serverless", outputs=producer_outputs()["serverless"])}[producer]
            document["outputs"][field] = document["outputs"][field].replace("123456789012", "999999999999")
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.build(**{producer: document})

    def test_cli_writes_only_inside_trusted_temp_and_redacts_failures(self):
        with trusted_temp_directory() as directory:
            platform = directory / "platform.json"
            platform.write_text(json.dumps(manifest()), encoding="utf-8")
            output = directory / "inputs.json"
            arguments = ["--component", "ingress", "--platform", str(platform), "--output", str(output),
                         "--environment", "homologation", "--account", "123456789012", "--owner", "garageflow", "--expires-on", "2026-09-11"]
            self.assertEqual(0, self.module.main(arguments))
            self.assertEqual("homologation", json.loads(output.read_text())["environment"])
            platform.write_text('{"password":"DO-NOT-PRINT"}', encoding="utf-8")
            errors = io.StringIO()
            with redirect_stderr(errors):
                self.assertEqual(2, self.module.main(arguments))
            self.assertNotIn("DO-NOT-PRINT", errors.getvalue())
            platform.write_text(json.dumps(manifest()), encoding="utf-8")
            arguments[arguments.index("--output") + 1] = str(ROOT / "forbidden.json")
            with redirect_stderr(io.StringIO()):
                self.assertEqual(2, self.module.main(arguments))
