#!/usr/bin/env python3
"""Build ingress/edge Terraform inputs from validated metadata only."""

import argparse
from datetime import date
import json
import re
import sys

from infra_contract import ContractError, _resolve_artifact_path, load_contract, validate_contract


def build_variables(*, component, platform, ingress=None, serverless=None, environment, account, owner, expires_on):
    if component not in ("ingress", "edge") or not re.fullmatch(r"[0-9]{12}", account):
        raise ValueError("Invalid component or expected AWS account")
    if not owner or owner != owner.strip() or len(owner) > 128 or any(ord(char) < 32 for char in owner):
        raise ValueError("Invalid owner tag")
    if date.fromisoformat(expires_on).isoformat() != expires_on:
        raise ValueError("Invalid expiry date")
    result = {"environment": environment, "owner": owner, "expires_on": expires_on}
    documents = [("platform", platform, "1.0")]
    if component == "edge":
        documents += [("ingress", ingress, "2.0"), ("serverless", serverless, "1.0")]
    for producer, document, version in documents:
        validated = validate_contract(document, producer, environment, schema_version=version)
        for value in validated["outputs"].values():
            if isinstance(value, str) and value.startswith("arn:"):
                parts = value.split(":")
                if parts[3] != "us-east-1" or parts[4] != account:
                    raise ValueError("Contract resource account or region mismatch")
        result[f"{producer}_contract"] = validated
    return result


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("component", "platform", "output", "environment", "account", "owner", "expires-on"):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--ingress")
    parser.add_argument("--serverless")
    options = parser.parse_args(arguments)
    try:
        documents = {producer: load_contract(getattr(options, producer), producer, options.environment, version)
                     for producer, version in [("platform", "1.0"), ("ingress", "2.0"), ("serverless", "1.0")]
                     if getattr(options, producer)}
        result = build_variables(component=options.component, environment=options.environment, account=options.account,
                                 owner=options.owner, expires_on=options.expires_on, **documents)
        _resolve_artifact_path(options.output).write_text(json.dumps(result, sort_keys=True) + "\n", encoding="utf-8")
        return 0
    except (ValueError, OSError, TypeError):
        print("Edge inputs rejected: invalid contract, identity, tags or temporary path.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
