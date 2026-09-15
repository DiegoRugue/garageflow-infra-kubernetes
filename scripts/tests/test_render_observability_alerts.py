import importlib
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


class AlertRendererTests(unittest.TestCase):
    def renderer(self):
        return importlib.import_module("render_observability_alerts")

    def test_renders_disabled_environment_scoped_conditions_and_policy_operations(self):
        renderer = self.renderer()
        production = renderer.build_alerts(8506965, "production")
        document = renderer.build_alerts(1234567, "homologation")
        self.assertEqual(1234567, document["accountId"])
        self.assertEqual("PER_CONDITION", document["policy"]["incidentPreference"])
        self.assertEqual(3, len(document["conditions"]))
        self.assertEqual(3, len(document["conditionMutations"]))
        for condition, mutation in zip(document["conditions"], document["conditionMutations"]):
            self.assertIs(False, condition["enabled"])
            query = condition["nrql"]["query"]
            self.assertIn("service.name = 'garageflow-api'", query)
            self.assertIn("deployment.environment.name = 'homologation'", query)
            self.assertNotRegex(query, r"\b(TIMESERIES|SINCE|LIMIT)\b")
            self.assertEqual("NONE", condition["signal"]["fillOption"])
            self.assertFalse(condition["expiration"]["closeViolationsOnExpiration"])
            self.assertFalse(condition["expiration"]["openViolationOnExpiration"])
            self.assertIn("alertsNrqlConditionStaticCreate", mutation)
            self.assertIn("$policyId", mutation)
            self.assertIn("accountId: 1234567", mutation)
            self.assertIn("enabled: false", mutation)
            self.assertIn(json.dumps(query, ensure_ascii=False), mutation)
        self.assertIn("policiesSearch", document["policyLookup"])
        self.assertIn("alertsPolicyCreate", document["policyMutation"])
        self.assertNotIn("${", json.dumps(document))
        self.assertNotIn("production", json.dumps(document))
        self.assertNotIn("homologation", json.dumps(production))
        self.assertNotIn("api-key", json.dumps(document).lower())
        self.assertNotIn("@", json.dumps(document))

    def test_counts_technical_failures_and_reuses_counter_contract(self):
        queries = [c["nrql"]["query"] for c in self.renderer().build_alerts(1, "production")["conditions"]]
        self.assertIn("filter(count(http.server.request.duration), WHERE http.response.status_code >= 500", queries[0])
        for route in ("'/work-orders'", "'/work-orders/%'", "'/me/work-orders'", "'/me/work-orders/%'", "'/webhooks/estimate-decisions'"):
            self.assertIn(route, queries[0])
        self.assertIn("sum(garageflow.integration.outbox.results)", queries[1])
        self.assertIn("outbox.failure.kind != 'none'", queries[1])
        self.assertIn("sum(garageflow.integration.outbox.polls)", queries[2])
        self.assertIn("outbox.outcome = 'failure'", queries[2])

    def test_rejects_invalid_account_environment_and_avoids_output_on_failure(self):
        renderer = self.renderer()
        for account in (True, 0, -1, 1.5, "8506965", 2147483648):
            with self.subTest(account=account), self.assertRaises(ValueError):
                renderer.build_alerts(account, "production")
        for environment in ("", None, "main", "production' OR true"):
            with self.subTest(environment=environment), self.assertRaises(ValueError):
                renderer.build_alerts(1, environment)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "alerts.json"
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
                renderer.main(["--account-id", "0", "--environment", "production", "--output", str(output)])
            self.assertEqual(2, failure.exception.code)
            self.assertFalse(output.exists())

    def test_cli_writes_utf8_and_reports_unwritable_path(self):
        renderer = self.renderer()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "alerts.json"
            args = ["--account-id", "8506965", "--environment", "production", "--output", str(output)]
            self.assertEqual(0, renderer.main(args))
            self.assertEqual(renderer.build_alerts(8506965, "production"), json.loads(output.read_text(encoding="utf-8")))
            args[-1] = directory
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
                renderer.main(args)
            self.assertEqual(2, failure.exception.code)


if __name__ == "__main__":
    unittest.main()
