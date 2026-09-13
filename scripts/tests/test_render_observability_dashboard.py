import importlib
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


class DashboardTests(unittest.TestCase):
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
        for page in renderer.build_dashboard(8506965, "production")["pages"]:
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
