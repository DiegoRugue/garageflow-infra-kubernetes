import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import deploy_observability as deploy
from test_infra_contract import manifest


class ObservabilityTests(unittest.TestCase):
    def inputs(self, **changes):
        values = dict(GITHUB_REF="refs/heads/develop", DEPLOY_ENVIRONMENT="homologation",
                      NEW_RELIC_ENABLED="true", NEW_RELIC_ACCOUNT_ID="8506965", NEW_RELIC_REGION="US",
                      NEW_RELIC_LICENSE_KEY="secret-never-print", EXPECTED_AWS_ACCOUNT_ID="123456789012",
                      AWS_REGION="us-east-1", TF_STATE_BUCKET="test-state-bucket")
        values.update(changes)
        return values

    def test_refuses_invalid_inputs_before_commands(self):
        for change in [dict(GITHUB_REF="refs/pull/1/merge"), dict(DEPLOY_ENVIRONMENT="production"),
                       dict(NEW_RELIC_ACCOUNT_ID="bad"), dict(NEW_RELIC_REGION="EU"),
                       dict(NEW_RELIC_LICENSE_KEY=""), dict(EXPECTED_AWS_ACCOUNT_ID="bad")]:
            with self.subTest(change=change), patch.object(deploy, "run") as command:
                with self.assertRaises(deploy.DeploymentError):
                    deploy.validate_inputs(self.inputs(**change))
                command.assert_not_called()

    def test_contract_requires_live_account_and_cluster_network(self):
        contract = manifest()
        outputs = contract["outputs"]
        live = {"name": outputs["clusterName"], "arn": "arn:aws:eks:us-east-1:123456789012:cluster/" + outputs["clusterName"],
                "resourcesVpcConfig": {"vpcId": outputs["vpcId"]}}
        self.assertEqual(outputs, deploy.validate_platform(contract, self.inputs(), live))
        live["resourcesVpcConfig"]["vpcId"] = "vpc-bad"
        with self.assertRaises(deploy.DeploymentError):
            deploy.validate_platform(contract, self.inputs(), live)

    def test_secret_only_in_stdin_and_failure_does_not_echo_payload(self):
        secret = "secret-never-print"
        with patch.dict(os.environ, NEW_RELIC_LICENSE_KEY=secret), patch.object(subprocess, "run") as command:
            command.return_value = subprocess.CompletedProcess([], 1, secret, secret)
            with self.assertRaises(deploy.DeploymentError) as error:
                deploy.apply_secret(secret)
            call = command.call_args
            self.assertNotIn(secret, str(call.args))
            self.assertNotIn("NEW_RELIC_LICENSE_KEY", call.kwargs["env"])
            self.assertIn(secret, call.kwargs["input"])
            self.assertNotIn(secret, str(error.exception))
            self.assertTrue(call.kwargs["capture_output"])

    def test_lease_restore_uses_ownership_check_and_removes_marker_after_success(self):
        original = {"endpointPublicAccess": False, "endpointPrivateAccess": True, "publicAccessCidrs": ["0.0.0.0/0"]}
        granted = {"endpointPublicAccess": True, "endpointPrivateAccess": True, "publicAccessCidrs": ["8.8.8.8/32"]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / deploy.LEASE_NAME
            path.write_text(json.dumps(dict(clusterName="garageflow-homologation", original=original, granted=granted, pendingUpdate=None)))
            with patch.object(deploy, "cluster_config", return_value=granted), patch.object(deploy, "update_access") as update:
                deploy.restore_access(Path(directory))
                self.assertEqual(("garageflow-homologation", original), update.call_args.args)
                self.assertFalse(path.exists())
            path.write_text(json.dumps(dict(clusterName="garageflow-homologation", original=original, granted=granted, pendingUpdate=None)))
            with patch.object(deploy, "cluster_config", return_value={**granted, "publicAccessCidrs": ["9.9.9.9/32"]}), patch.object(deploy, "update_access") as update:
                with self.assertRaises(deploy.DeploymentError):
                    deploy.restore_access(Path(directory))
                update.assert_not_called()
                self.assertTrue(path.exists())

    def test_receiver_contract_and_bounded_export(self):
        values = json.loads((deploy.ROOT / "observability/values.json").read_text())
        self.assertEqual(
            ["daemonsets", "deployments", "horizontalpodautoscalers", "jobs", "namespaces", "nodes", "pods", "replicasets", "statefulsets"],
            values["kube-state-metrics"]["collectors"],
            "Explicit discovery allowlist must exclude Secrets and ConfigMaps",
        )
        self.assertFalse(values["receivers"]["filelog"]["enabled"])
        config = values["deployment"]["configMap"]["extraConfig"]
        self.assertEqual("0.0.0.0:4318", config["receivers"]["otlp/app"]["protocols"]["http"]["endpoint"])
        for signal in ("traces", "metrics", "logs"):
            pipeline = config["pipelines"][signal + "/app"]
            self.assertEqual(["otlp/app"], pipeline["receivers"])
            self.assertEqual("memory_limiter", pipeline["processors"][0])
        service = deploy.receiver_service()
        self.assertEqual("ClusterIP", service["spec"]["type"])
        self.assertEqual("garageflow-otel", service["metadata"]["name"])
        self.assertEqual(4318, service["spec"]["ports"][0]["port"])

    def test_daemonset_cloud_detection_uses_only_environment_without_aws_credentials(self):
        values = json.loads((deploy.ROOT / "observability/values.json").read_text())
        self.assertIn(
            "--config=yaml:processors::resource_detection/cloudproviders::detectors: [env]",
            values["daemonset"]["extraArgs"],
        )
        for workload in ("daemonset", "deployment"):
            self.assertFalse(any(item["name"].startswith("AWS_") for item in values[workload]["envs"]))

    def test_chart_checksum_rejects_changed_release(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(deploy, "download", return_value=b"wrong"):
            with self.assertRaises(deploy.DeploymentError):
                deploy.fetch_chart(Path(directory))

    def test_pending_grant_timeout_preserves_lease_until_terminal_update(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / deploy.LEASE_NAME
            lease = dict(clusterName="garageflow-homologation", original={}, granted={}, pendingUpdate="update-123")
            path.write_text(json.dumps(lease))
            with patch.object(deploy, "wait_update", side_effect=deploy.DeploymentError("timeout")), patch.object(deploy, "cluster_config") as read:
                with self.assertRaises(deploy.DeploymentError):
                    deploy.restore_access(Path(directory))
                read.assert_not_called()
                self.assertTrue(path.exists())
            lease["pendingUpdate"] = "uncertain"
            path.write_text(json.dumps(lease))
            with self.assertRaises(deploy.DeploymentError):
                deploy.restore_access(Path(directory))
            self.assertTrue(path.exists())

    def test_reordered_granted_cidrs_restore_original_access(self):
        original = dict(endpointPublicAccess=True, endpointPrivateAccess=True,
                        publicAccessCidrs=["9.9.9.9/32", "8.8.8.8/32"])
        granted = {**original, "publicAccessCidrs": [*original["publicAccessCidrs"], "1.1.1.1/32"]}
        current = {**granted, "publicAccessCidrs": list(reversed(granted["publicAccessCidrs"]))}
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / deploy.LEASE_NAME
            marker.write_text(json.dumps(dict(clusterName="garageflow-production", original=original,
                                             granted=granted, pendingUpdate=None)))
            with patch.object(deploy, "cluster_config", return_value=current), patch.object(deploy, "update_access") as update:
                deploy.restore_access(Path(directory))
                self.assertEqual(("garageflow-production", original), update.call_args.args)
                self.assertFalse(marker.exists())

    def test_reordered_original_cidrs_clear_lease_without_aws_update(self):
        original = dict(endpointPublicAccess=True, endpointPrivateAccess=True,
                        publicAccessCidrs=["9.9.9.9/32", "8.8.8.8/32"])
        granted = {**original, "publicAccessCidrs": [*original["publicAccessCidrs"], "1.1.1.1/32"]}
        current = {**original, "publicAccessCidrs": list(reversed(original["publicAccessCidrs"]))}
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / deploy.LEASE_NAME
            marker.write_text(json.dumps(dict(clusterName="garageflow-production", original=original,
                                             granted=granted, pendingUpdate=None)))
            with patch.object(deploy, "cluster_config", return_value=current), patch.object(deploy, "update_access") as update:
                deploy.restore_access(Path(directory))
                update.assert_not_called()
                self.assertFalse(marker.exists())

    def test_changed_network_or_endpoint_flags_still_preserve_lease(self):
        original = dict(endpointPublicAccess=True, endpointPrivateAccess=True, publicAccessCidrs=["9.9.9.9/32"])
        granted = {**original, "publicAccessCidrs": ["9.9.9.9/32", "1.1.1.1/32"]}
        for changes in ({"publicAccessCidrs": ["9.9.9.9/32", "8.8.8.8/32"]},
                        {"endpointPublicAccess": False}, {"endpointPrivateAccess": False}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                marker = Path(directory) / deploy.LEASE_NAME
                marker.write_text(json.dumps(dict(clusterName="garageflow-production", original=original,
                                                 granted=granted, pendingUpdate=None)))
                with patch.object(deploy, "cluster_config", return_value={**granted, **changes}), patch.object(deploy, "update_access") as update:
                    with self.assertRaises(deploy.DeploymentError):
                        deploy.restore_access(Path(directory))
                    update.assert_not_called()
                    self.assertTrue(marker.exists())

    def test_install_failure_restores_access_and_never_passes_key_to_helm(self):
        document = manifest()
        outputs = document["outputs"]
        cluster = dict(name=outputs["clusterName"], arn=f"arn:aws:eks:us-east-1:123456789012:cluster/{outputs['clusterName']}", resourcesVpcConfig=dict(vpcId=outputs["vpcId"]))
        calls = []
        def command(args, **kwargs):
            calls.append((args, kwargs))
            if args[:3] == ["aws", "s3", "cp"]:
                return json.dumps(document)
            if args[0] == "helm":
                raise deploy.DeploymentError("helm failed")
            return ""
        with tempfile.TemporaryDirectory() as directory, patch.object(deploy, "run", side_effect=command), patch.object(deploy, "aws", side_effect=[{"Account":"123456789012"},{"cluster":cluster}]), patch.object(deploy, "fetch_chart", return_value=Path(directory)/"collector.tgz"), patch.object(deploy, "grant_access") as grant, patch.object(deploy, "restore_access") as restore:
            with self.assertRaises(deploy.DeploymentError):
                deploy.install(self.inputs(), Path(directory), Path(directory))
            grant.assert_called_once()
            restore.assert_called_once()
        helm = next(args for args, kwargs in calls if args[0] == "helm")
        self.assertNotIn("secret-never-print", str(helm))
        self.assertIn("--atomic", helm)
        self.assertIn("--values", helm)

    def test_grant_validates_scope_and_persists_submission_before_waiting(self):
        original = dict(endpointPublicAccess=True, endpointPrivateAccess=True, publicAccessCidrs=["9.9.9.9/32"])
        def submitted(cluster, config, submitted):
            submitted("update-id")
            raise deploy.DeploymentError("timeout")
        with tempfile.TemporaryDirectory() as directory, patch.object(deploy, "download", return_value=b"8.8.8.8"), patch.object(deploy, "cluster_config", return_value=original), patch.object(deploy, "update_access", side_effect=submitted):
            with self.assertRaises(deploy.DeploymentError):
                deploy.grant_access("garageflow-homologation", Path(directory))
            lease = json.loads((Path(directory)/deploy.LEASE_NAME).read_text())
            self.assertEqual("update-id", lease["pendingUpdate"])
            self.assertEqual(["9.9.9.9/32", "8.8.8.8/32"], lease["granted"]["publicAccessCidrs"])

    def test_workflow_is_opt_in_protected_and_has_unconditional_cleanup(self):
        workflow = (deploy.ROOT / ".github/workflows/deploy-observability.yml").read_text()
        self.assertIn("needs: quality-gate", workflow)
        self.assertIn("github.ref == 'refs/heads/main' || github.ref == 'refs/heads/develop'", workflow)
        self.assertIn("vars.NEW_RELIC_ENABLED || 'false'", workflow)
        self.assertIn("if: always()", workflow)
        self.assertIn("python scripts/deploy_observability.py cleanup", workflow)
        self.assertIn("./.github/workflows/deploy-observability.yml", (deploy.ROOT / ".github/workflows/deploy.yml").read_text())

    def test_disabled_installation_never_contacts_aws(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, RUNNER_TEMP=directory, NEW_RELIC_ENABLED="false"), patch.object(sys, "argv", ["deploy_observability.py"]), patch.object(deploy, "aws") as provider:
            deploy.main()
            provider.assert_not_called()

    def test_update_submission_is_recorded_before_poll_and_terminal_failure_raises(self):
        order = []
        def submitted(identifier):
            order.append(identifier)
        def wait(cluster, identifier):
            self.assertEqual(["update-1"], order)
            return "Failed"
        with patch.object(deploy, "aws", return_value={"update":{"id":"update-1"}}), patch.object(deploy, "wait_update", side_effect=wait):
            with self.assertRaises(deploy.DeploymentError):
                deploy.update_access("garageflow-production", {}, submitted)

    def test_update_poll_waits_for_terminal_state(self):
        with patch.object(deploy, "aws", side_effect=[{"update":{"status":"InProgress"}}, {"update":{"status":"Successful"}}]), patch.object(deploy.time, "sleep") as sleep:
            self.assertEqual("Successful", deploy.wait_update("garageflow-production", "update-1"))
            sleep.assert_called_once_with(10)

    def test_private_original_endpoint_does_not_grant_worldwide_default_cidr(self):
        original = dict(endpointPublicAccess=False, endpointPrivateAccess=True, publicAccessCidrs=["0.0.0.0/0"])
        with tempfile.TemporaryDirectory() as directory, patch.object(deploy, "download", return_value=b"8.8.8.8"), patch.object(deploy, "cluster_config", return_value=original), patch.object(deploy, "update_access") as update:
            deploy.grant_access("garageflow-homologation", Path(directory))
            self.assertEqual(["8.8.8.8/32"], update.call_args.args[1]["publicAccessCidrs"])

    def test_success_preserves_named_env_list_and_rolls_out_secret_rotation(self):
        document = manifest()
        outputs = document["outputs"]
        cluster = dict(name=outputs["clusterName"], arn=f"arn:aws:eks:us-east-1:123456789012:cluster/{outputs['clusterName']}", resourcesVpcConfig=dict(vpcId=outputs["vpcId"]))
        calls = []
        def command(args, **kwargs):
            calls.append(args)
            return json.dumps(document) if args[:3] == ["aws", "s3", "cp"] else ""
        with tempfile.TemporaryDirectory() as directory, patch.object(deploy, "run", side_effect=command), patch.object(deploy, "aws", side_effect=[{"Account":"123456789012"},{"cluster":cluster}]), patch.object(deploy, "fetch_chart", return_value=Path(directory)/"collector.tgz"), patch.object(deploy, "grant_access"), patch.object(deploy, "restore_access") as restore:
            deploy.install(self.inputs(), Path(directory), Path(directory))
            settings = json.loads((Path(directory)/"values.json").read_text())
            env = {item["name"]:item["value"] for item in settings["deployment"]["envs"]}
            self.assertEqual("homologation", env["DEPLOYMENT_ENVIRONMENT"])
            self.assertEqual(outputs["clusterName"], env["CLUSTER_NAME"])
            self.assertIn("GOMEMLIMIT", env)
            self.assertNotIn("secret-never-print", json.dumps(settings))
            restore.assert_called_once()
        self.assertEqual(2, len([args for args in calls if args[:3] == ["kubectl", "rollout", "restart"]]))
