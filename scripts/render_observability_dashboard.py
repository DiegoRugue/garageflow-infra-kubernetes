#!/usr/bin/env python3
"""Render an importable New Relic dashboard for one account and environment."""

import argparse
import json
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parents[1] / "observability" / "dashboards" / "technical.json"


def build_dashboard(account_id, environment):
    if type(account_id) is not int or account_id <= 0:
        raise ValueError("New Relic account ID must be a positive integer")
    if environment not in ("production", "homologation"):
        raise ValueError("Environment must be production or homologation")
    document = json.loads(TEMPLATE.read_text(encoding="utf-8").replace("${ENVIRONMENT}", environment))
    for page in document["pages"]:
        for widget in page["widgets"]:
            for query in widget["rawConfiguration"].get("nrqlQueries", []):
                query["accountIds"] = [account_id]
    return document


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--account-id", type=int, required=True)
    parser.add_argument("--environment", choices=("production", "homologation"), required=True)
    parser.add_argument("--output", type=Path, required=True, help="External output path for dashboard import")
    options = parser.parse_args(arguments)
    try:
        document = build_dashboard(options.account_id, options.environment)
        options.output.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    except (ValueError, OSError):
        parser.error("Dashboard rendering failed; check account ID and output path")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
