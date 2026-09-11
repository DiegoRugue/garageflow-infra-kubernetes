import json
import shutil
import subprocess
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
WINDOWS_GIT_BASH = Path("C:/Program Files/Git/bin/bash.exe")
BASH = str(WINDOWS_GIT_BASH) if WINDOWS_GIT_BASH.exists() else shutil.which("bash")


@unittest.skipIf(BASH is None, "bash is required for deployment-script behavior tests")
class DeployPlatformBehaviorTests(unittest.TestCase):
    def run_bash(self, body: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [BASH, "-c", "set -Eeuo pipefail\n" + body],
            cwd=REPOSITORY_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_runner_public_ipv4_is_appended_as_32_without_replacing_configured_cidrs(self) -> None:
        result = self.run_bash(
            r'''
            source scripts/lib/deploy-platform-functions.sh
            export PYTHON_BIN=python
            curl() { printf '8.8.8.8\n'; }
            resolve_runner_access_cidrs '["198.51.100.10/32", "203.0.113.0/24"]'
            '''
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            ["198.51.100.10/32", "203.0.113.0/24", "8.8.8.8/32"],
            json.loads(result.stdout),
        )

    def test_runner_ip_lookup_fails_closed_for_non_public_ipv4(self) -> None:
        result = self.run_bash(
            r'''
            source scripts/lib/deploy-platform-functions.sh
            export PYTHON_BIN=python
            curl() { printf '10.0.0.7\n'; }
            resolve_runner_access_cidrs '["203.0.113.10/32"]'
            '''
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("public IPv4", result.stderr)
        self.assertEqual("", result.stdout)

    def test_runner_ip_lookup_failure_stops_without_a_cidr_fallback(self) -> None:
        result = self.run_bash(
            r'''
            source scripts/lib/deploy-platform-functions.sh
            export PYTHON_BIN=python
            curl() { return 28; }
            resolve_runner_access_cidrs '["203.0.113.10/32"]'
            '''
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("unable to determine", result.stderr)
        self.assertEqual("", result.stdout)

    def test_ready_node_probe_retries_a_failed_request_then_accepts_two_ready_nodes(self) -> None:
        result = self.run_bash(
            r'''
            source scripts/lib/deploy-platform-functions.sh
            attempt_file="$(mktemp)"
            clock_file="$(mktemp)"
            trap 'rm -f -- "${attempt_file}" "${clock_file}"' EXIT
            printf '0' > "${attempt_file}"
            printf '100' > "${clock_file}"
            now_epoch_seconds() {
              local current
              current="$(cat "${clock_file}")"
              printf '%s' "$((current + 1))" > "${clock_file}"
              printf '%s\n' "${current}"
            }
            sleep() { :; }
            kubectl() {
              local attempt
              [[ "$*" == *"--request-timeout=2s"* ]] || return 64
              attempt="$(cat "${attempt_file}")"
              attempt=$((attempt + 1))
              printf '%s' "${attempt}" > "${attempt_file}"
              if (( attempt == 1 )); then
                printf 'temporary API timeout\n' >&2
                return 42
              fi
              printf 'node-a Ready worker 1m v1.36.0\nnode-b Ready worker 1m v1.36.0\n'
            }
            wait_for_ready_nodes 10 1 2s
            '''
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("2 Ready nodes", result.stdout)

    def test_ready_node_probe_reports_persistent_failure_at_deadline(self) -> None:
        result = self.run_bash(
            r'''
            source scripts/lib/deploy-platform-functions.sh
            clock_file="$(mktemp)"
            trap 'rm -f -- "${clock_file}"' EXIT
            printf '200' > "${clock_file}"
            now_epoch_seconds() {
              local current
              current="$(cat "${clock_file}")"
              printf '%s' "$((current + 1))" > "${clock_file}"
              printf '%s\n' "${current}"
            }
            sleep() { :; }
            kubectl() { return 42; }
            wait_for_ready_nodes 3 1 2s
            '''
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("deadline", result.stderr)
        self.assertIn("exit status 42", result.stderr)
        self.assertNotIn("Ready nodes", result.stdout)


if __name__ == "__main__":
    unittest.main()
