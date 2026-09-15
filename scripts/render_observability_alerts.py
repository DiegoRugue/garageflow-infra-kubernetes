#!/usr/bin/env python3
"""Render disabled New Relic alert definitions and NerdGraph operations offline."""

import argparse
import copy
import json
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parents[1] / "observability" / "alerts" / "processing.json"


def condition_mutation(account_id, condition):
    """Policy ID is supplied as a GraphQL variable after lookup/creation."""
    signal = condition["signal"]
    term = condition["terms"][0]
    return f'''mutation($policyId: ID!) {{
  alertsNrqlConditionStaticCreate(
    accountId: {account_id}
    policyId: $policyId
    condition: {{
      name: {json.dumps(condition["name"], ensure_ascii=False)}
      description: {json.dumps(condition["description"], ensure_ascii=False)}
      enabled: false
      nrql: {{ query: {json.dumps(condition["nrql"]["query"], ensure_ascii=False)} }}
      signal: {{
        aggregationWindow: {signal["aggregationWindow"]}
        aggregationMethod: {signal["aggregationMethod"]}
        aggregationDelay: {signal["aggregationDelay"]}
        fillOption: {signal["fillOption"]}
      }}
      terms: [{{
        operator: {term["operator"]}
        priority: {term["priority"]}
        threshold: {term["threshold"]}
        thresholdDuration: {term["thresholdDuration"]}
        thresholdOccurrences: {term["thresholdOccurrences"]}
      }}]
      expiration: {{ closeViolationsOnExpiration: false, openViolationOnExpiration: false }}
      violationTimeLimitSeconds: {condition["violationTimeLimitSeconds"]}
    }}
  ) {{ id name enabled }}
}}'''


def build_alerts(account_id, environment):
    if type(account_id) is not int or not 0 < account_id <= 2147483647:
        raise ValueError("New Relic account ID must be a positive GraphQL Int")
    if environment not in ("production", "homologation"):
        raise ValueError("Environment must be production or homologation")
    template = json.loads(TEMPLATE.read_text(encoding="utf-8").replace("${ENVIRONMENT}", environment))
    conditions = [copy.deepcopy(template["defaults"]) | item for item in template["conditions"]]
    policy = template["policy"]
    name = json.dumps(policy["name"], ensure_ascii=False)
    return {
        "accountId": account_id,
        "environment": environment,
        "policy": policy,
        "conditions": conditions,
        "policyLookup": f'{{ actor {{ account(id: {account_id}) {{ alerts {{ policiesSearch(searchCriteria: {{ nameLike: {name} }}) {{ policies {{ id name }} }} }} }} }} }}',
        "policyMutation": f'mutation {{ alertsPolicyCreate(accountId: {account_id}, policy: {{ name: {name}, incidentPreference: {policy["incidentPreference"]} }}) {{ id name }} }}',
        "conditionMutations": [condition_mutation(account_id, condition) for condition in conditions],
        "instructions": "Use existing matching policy/conditions when present; create mutations are not idempotent. Supply the selected policy ID as the policyId GraphQL variable for each condition mutation. These definitions are disabled. Configure a notification workflow separately, validate merged telemetry and then enable the conditions. This file is not a dashboard import document. Signal loss and automatic incident closure do not prove recovery.",
    }


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--account-id", type=int, required=True)
    parser.add_argument("--environment", choices=("production", "homologation"), required=True)
    parser.add_argument("--output", type=Path, required=True, help="External path for definitions and NerdGraph operations")
    options = parser.parse_args(arguments)
    try:
        document = build_alerts(options.account_id, options.environment)
        options.output.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except (ValueError, OSError):
        parser.error("Alert rendering failed; check account ID and output path")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
