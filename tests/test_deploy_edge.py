import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_deploy_platform import BASH, REPOSITORY_ROOT

sys.path.insert(0, str(REPOSITORY_ROOT / "scripts" / "tests"))
from test_infra_contract import manifest, producer_outputs
from test_ingress_contract_v2 import ingress_v2


@unittest.skipIf(BASH is None, "bash is required")
class EdgeDeploymentTests(unittest.TestCase):
    def run_deployment(self, component="ingress", **changes):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            (temporary / "platform-fixture.json").write_text(json.dumps(manifest()), encoding="utf-8")
            (temporary / "outputs-fixture.json").write_text(json.dumps(ingress_v2()["outputs"]), encoding="utf-8")
            (temporary / "ingress-fixture.json").write_text(json.dumps(ingress_v2()), encoding="utf-8")
            (temporary / "serverless-fixture.json").write_text(json.dumps(manifest("serverless", outputs=producer_outputs()["serverless"])), encoding="utf-8")
            environment = dict(os.environ, AWS_ACCESS_KEY_ID="test", AWS_SECRET_ACCESS_KEY="DO-NOT-PRINT",
                               AWS_SESSION_TOKEN="DO-NOT-PRINT", AWS_REGION="us-east-1", TF_STATE_BUCKET="test-state-bucket",
                               EXPECTED_AWS_ACCOUNT_ID="123456789012", DEPLOY_ENVIRONMENT="homologation",
                               TF_VAR_owner="garageflow", TF_VAR_expires_on="2026-09-11", GITHUB_REF="refs/heads/develop",
                               GITHUB_SHA="a" * 40, GITHUB_RUN_ID="12", GITHUB_RUN_ATTEMPT="1",
                               RUNNER_TEMP=temporary.as_posix(), GF_TEST_PYTHON=Path(sys.executable).as_posix())
            environment["TEST_COMPONENT"] = component
            environment.update(changes)
            script = r'''
            python() {
              if [[ "$1" == *edge_preflight.py ]]; then [[ "${FAIL_PREREQUISITES:-0}" == 0 ]]
              else command "$GF_TEST_PYTHON" "$@"; fi
            }
            aws() {
              printf 'aws %s\n' "$*" >>"$RUNNER_TEMP/trace"
              if [[ "$1 $2" == 'sts get-caller-identity' ]]; then printf '%s' "${MOCK_ACCOUNT:-123456789012}"
              elif [[ "$1 $2" == 's3 cp' && "$3" == s3://* ]]; then
                [[ "${MISSING_CONTRACT:-0}" == 0 ]] || return 1
                contract_name="${3##*/}"
                cp "$RUNNER_TEMP/${contract_name%.json}-fixture.json" "$4"
              fi
            }
            terraform() {
              printf 'terraform %s\n' "$*" >>"$RUNNER_TEMP/trace"
              if [[ "$2" == apply && "${FAIL_APPLY:-0}" == 1 ]]; then return 1; fi
              if [[ "$2" == output ]]; then
                if [[ "$TEST_COMPONENT" == edge ]]; then printf 'https://test.execute-api.us-east-1.amazonaws.com'
                else cat "$RUNNER_TEMP/outputs-fixture.json"; fi
              fi
            }
            export -f aws terraform python
            bash "scripts/deploy-${TEST_COMPONENT}.sh"
            '''
            result = subprocess.run([BASH, "-c", script], cwd=REPOSITORY_ROOT, env=environment, text=True, capture_output=True)
            trace = (temporary / "trace").read_text() if (temporary / "trace").exists() else ""
            self.assertNotIn("DO-NOT-PRINT", result.stdout + result.stderr + trace)
            self.assertFalse(list(temporary.glob(f"garageflow-{component}.*")), "Temporary artifacts must be cleaned")
            return result, trace

    def test_rejects_untrusted_branch_before_aws(self):
        result, trace = self.run_deployment(GITHUB_REF="refs/pull/1/merge")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual("", trace)

    def test_rejects_wrong_account_or_missing_contract_before_terraform(self):
        for changes in [dict(MOCK_ACCOUNT="999999999999"), dict(MISSING_CONTRACT="1")]:
            result, trace = self.run_deployment(**changes)
            self.assertNotEqual(0, result.returncode)
            self.assertNotIn("terraform", trace)

    def test_failed_apply_never_publishes_contract(self):
        result, trace = self.run_deployment(FAIL_APPLY="1")
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("put-object", trace)

    def test_success_publishes_immutable_revision_before_stable_contract(self):
        result, trace = self.run_deployment()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("key=phase3/homologation/ingress.tfstate", trace)
        self.assertIn("--if-none-match *", trace)
        self.assertLess(trace.index("put-object"), trace.index("s3://test-state-bucket/contracts/v2/homologation/ingress.json"))

    def test_edge_consumes_all_prerequisites_uses_own_state_and_does_not_publish_metadata(self):
        result, trace = self.run_deployment(component="edge")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("contracts/v2/homologation/ingress.json", trace)
        self.assertIn("contracts/v1/homologation/serverless.json", trace)
        self.assertIn("key=phase3/homologation/edge.tfstate", trace)
        self.assertIn("https://test.execute-api", result.stdout)
        self.assertNotIn("put-object", trace)

    def test_edge_stale_or_missing_prerequisites_never_apply(self):
        for changes in [dict(MISSING_CONTRACT="1"), dict(FAIL_PREREQUISITES="1")]:
            result, trace = self.run_deployment(component="edge", **changes)
            self.assertNotEqual(0, result.returncode)
            self.assertNotIn("terraform", trace)
