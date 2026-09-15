import importlib
import io
import json
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


class DashboardTests(unittest.TestCase):
    def test_default_and_explicit_technical_selection_preserve_existing_dashboard(self):
        renderer = importlib.import_module("render_observability_dashboard")
        default = renderer.build_dashboard(8506965, "production")
        self.assertEqual("GarageFlow - Technical - production", default["name"])
        self.assertEqual(default, renderer.build_dashboard(8506965, "production", "technical"))
        self.assertEqual(["API", "Kubernetes"], [page["name"] for page in default["pages"]])

    def test_business_cli_writes_import_document_for_selected_account_and_environment(self):
        renderer = importlib.import_module("render_observability_dashboard")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "business.json"
            self.assertEqual(0, renderer.main([
                "--account-id", "1234567", "--environment", "homologation",
                "--dashboard", "business", "--output", str(output),
            ]))
            document = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual("GarageFlow - Business - homologation", document["name"])
        self.assertEqual("PRIVATE", document["permissions"])
        self.assertEqual(2, len(document["pages"]))
        self.assertEqual(4, len(document["pages"][0]["widgets"]))
        for widget in [widget for page in document["pages"] for widget in page["widgets"]]:
            for query in widget["rawConfiguration"].get("nrqlQueries", []):
                self.assertEqual([1234567], query["accountIds"])
                self.assertIn("deployment.environment.name = 'homologation'", query["query"])
        self.assertNotIn("${", json.dumps(document))
        self.assertNotIn("production", json.dumps(document))

    def test_rejects_unknown_dashboard_and_business_invalid_inputs(self):
        renderer = importlib.import_module("render_observability_dashboard")
        for dashboard in ["", "../technical", "all", None]:
            with self.subTest(dashboard=dashboard), self.assertRaises(ValueError):
                renderer.build_dashboard(8506965, "production", dashboard)
        for account in [0, -1, True, "8506965", 1.5]:
            with self.subTest(account=account), self.assertRaises(ValueError):
                renderer.build_dashboard(account, "production", "business")
        for environment in ["", "main", "production' OR true", None]:
            with self.subTest(environment=environment), self.assertRaises(ValueError):
                renderer.build_dashboard(8506965, environment, "business")

    def test_business_queries_use_latest_daily_snapshots_without_replica_sums(self):
        renderer = importlib.import_module("render_observability_dashboard")
        document = renderer.build_dashboard(8506965, "production", "business")
        queries = [query["query"] for widget in document["pages"][0]["widgets"]
                   for query in widget["rawConfiguration"].get("nrqlQueries", [])]
        for query in queries:
            self.assertTrue(query.startswith("FROM Metric SELECT "))
            self.assertIn("service.name = 'garageflow-api'", query)
            self.assertIn("deployment.environment.name = 'production'", query)
            self.assertIn("work_orders.timezone = 'America/Sao_Paulo'", query)
            self.assertIn("FACET work_orders.date ORDER BY max(garageflow.work_orders.snapshot.timestamp) "
                          "LIMIT 7 SINCE 15 minutes ago", query)
            self.assertNotRegex(query.lower(), r"\b(sum|average|count|rate)\s*\(|\btimeseries\b")
            self.assertEqual({"work_orders.date", "work_orders.timezone"},
                             set(re.findall(r"(?<![\w.])work_orders\.[a-z_]+", query)))
        self.assertIn("latest(garageflow.work_orders.created)", queries[0])
        self.assertIn("latest(garageflow.work_orders.completed)", queries[1])
        self.assertIn("if(latest(garageflow.work_orders.completed) > 0, "
                      "latest(garageflow.work_orders.duration.mean) / 60)", queries[2])
        self.assertIn("latest(garageflow.work_orders.completed)", queries[2])
        self.assertIn("latest(garageflow.work_orders.snapshot.timestamp) * 1000", queries[2])
        self.assertIn("toDatetime(", queries[2])
        self.assertIn("'yyyy-MM-dd HH:mm:ss', timezone: 'America/Sao_Paulo'", queries[2])

    def test_processing_page_uses_failures_not_expected_rejections_or_sampled_spans(self):
        renderer = importlib.import_module("render_observability_dashboard")
        document = renderer.build_dashboard(8506965, "production", "business")
        self.assertEqual("Falhas e integrações", document["pages"][1]["name"])
        queries = [item["query"] for widget in document["pages"][1]["widgets"]
                   for item in widget["rawConfiguration"].get("nrqlQueries", [])]
        self.assertEqual(5, len(queries))
        for query in queries:
            self.assertIn("service.name = 'garageflow-api'", query)
            self.assertIn("deployment.environment.name = 'production'", query)
            self.assertNotIn("FROM Span", query)
            self.assertNotIn("SINCE 15 minutes ago", query)
        self.assertIn("http.response.status_code >= 500", queries[0])
        self.assertIn("sum(garageflow.integration.outbox.results)", queries[1])
        self.assertIn("outbox.failure.kind != 'none'", queries[2])
        self.assertIn("sum(garageflow.integration.outbox.polls)", queries[3])
        self.assertIn("outbox.outcome = 'failure'", queries[3])
        self.assertIn("EventName IN ('OutboxResult', 'OutboxPollFailure')", queries[4])
        self.assertIn("CorrelationId", queries[4])
        self.assertNotIn("message,", queries[4])

    def test_cli_writes_importable_document_and_rejects_invalid_account(self):
        renderer = importlib.import_module("render_observability_dashboard")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "dashboard.json"
            arguments = ["--account-id", "8506965", "--environment", "production", "--output", str(output)]
            self.assertEqual(0, renderer.main(arguments))
            self.assertEqual("PRIVATE", json.loads(output.read_text())["permissions"])
            arguments[1] = "0"
            with redirect_stderr(io.StringIO()) as error, self.assertRaises(SystemExit) as result:
                renderer.main(arguments)
            self.assertEqual(2, result.exception.code)
            self.assertIn("Dashboard rendering failed", error.getvalue())

    def test_all_queries_use_selected_account_and_environment_without_cross_run_mutation(self):
        renderer = importlib.import_module("render_observability_dashboard")
        production = renderer.build_dashboard(8506965, "production")
        homologation = renderer.build_dashboard(1234567, "homologation")
        for document, account, environment in [(production, 8506965, "production"),
                                                (homologation, 1234567, "homologation")]:
            self.assertEqual("PRIVATE", document["permissions"])
            self.assertIn(environment, document["name"])
            queries = [query for page in document["pages"] for widget in page["widgets"]
                       for query in widget["rawConfiguration"].get("nrqlQueries", [])]
            self.assertGreaterEqual(len(queries), 6)
            for query in queries:
                self.assertEqual([account], query["accountIds"])
                self.assertIn(environment, query["query"])
                self.assertNotIn("${", query["query"])
            self.assertNotIn("NEW_RELIC_LICENSE_KEY", json.dumps(document))
        self.assertNotIn("homologation", json.dumps(production))

    def test_rejects_invalid_account_or_environment_before_rendering(self):
        renderer = importlib.import_module("render_observability_dashboard")
        for account in [0, -1, True, "8506965", 1.5]:
            with self.subTest(account=account), self.assertRaises(ValueError):
                renderer.build_dashboard(account, "production")
        for environment in ["", "main", "production' OR true", None]:
            with self.subTest(environment=environment), self.assertRaises(ValueError):
                renderer.build_dashboard(8506965, environment)

    def test_widgets_fit_grid_without_overlap_and_have_unique_titles(self):
        renderer = importlib.import_module("render_observability_dashboard")
        pages = [page for dashboard in ("technical", "business")
                 for page in renderer.build_dashboard(8506965, "production", dashboard)["pages"]]
        for page in pages:
            occupied = set()
            titles = set()
            for widget in page["widgets"]:
                self.assertNotIn(widget["title"], titles)
                titles.add(widget["title"])
                layout = widget["layout"]
                cells = {(column, row)
                         for column in range(layout["column"], layout["column"] + layout["width"])
                         for row in range(layout["row"], layout["row"] + layout["height"])}
                self.assertTrue(all(1 <= column <= 12 and row >= 1 for column, row in cells))
                self.assertFalse(cells & occupied)
                occupied |= cells


if __name__ == "__main__":
    unittest.main()
