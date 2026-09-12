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


class EdgePreflightTests(unittest.TestCase):
    def setUp(self):
        self.module = importlib.import_module("edge_preflight")
        self.inputs = {"platform_contract": manifest(), "ingress_contract": ingress_v2(),
                       "serverless_contract": manifest("serverless", outputs=producer_outputs()["serverless"])}
        platform, ingress = self.inputs["platform_contract"]["outputs"], self.inputs["ingress_contract"]["outputs"]
        self.auth = {"State": "Active", "LastUpdateStatus": "Successful", "Environment": {"Variables": {
            "JWT_SECRET_ARN": platform["jwtSecretArn"], "INTERNAL_AUTH_SECRET_ARN": platform["internalAuthSecretArn"],
            "INTERNAL_API_BASE_URL": ingress["internalApiBaseUrl"], "INTERNAL_API_TRANSPORT": ingress["transport"]}},
            "VpcConfig": {"VpcId": platform["vpcId"], "SubnetIds": platform["privateApplicationSubnetIds"], "SecurityGroupIds": [ingress["authenticationSecurityGroupId"]]}}
        self.authorizer = {"State": "Active", "LastUpdateStatus": "Successful", "Environment": {"Variables": {"JWT_SECRET_ARN": platform["jwtSecretArn"]}}}
        self.listener = {"Listeners": [{"DefaultActions": [{"Type": "forward", "TargetGroupArn": "target"}]}]}
        self.targets = {"TargetHealthDescriptions": [{"TargetHealth": {"State": "healthy"}}]}

    def verify(self):
        responses = iter([self.auth, self.authorizer, self.listener, self.targets])
        self.module.verify(self.inputs, cloud=lambda *args: next(responses))

    def test_current_aliases_and_healthy_application_pass(self):
        self.verify()

    def test_stale_or_unready_alias_is_rejected(self):
        for name, value in [("JWT_SECRET_ARN", "old"), ("INTERNAL_API_BASE_URL", "http://old.example.com"), ("INTERNAL_AUTH_SECRET_ARN", "old")]:
            with self.subTest(name=name):
                self.setUp()
                self.auth["Environment"]["Variables"][name] = value
                with self.assertRaises(ValueError):
                    self.verify()
        self.setUp()
        self.auth["VpcConfig"]["SubnetIds"] = ["stale-subnet"]
        with self.assertRaises(ValueError):
            self.verify()
        self.setUp()
        self.authorizer["State"] = "Pending"
        with self.assertRaises(ValueError):
            self.verify()

    def test_missing_unhealthy_or_redirecting_application_is_rejected(self):
        for state in [[], [{"TargetHealth": {"State": "initial"}}]]:
            self.targets["TargetHealthDescriptions"] = state
            with self.assertRaises(ValueError):
                self.verify()
        self.listener["Listeners"][0]["DefaultActions"] = [{"Type": "redirect"}]
        with self.assertRaises(ValueError):
            self.verify()

    def test_aws_and_cli_errors_do_not_expose_captured_data(self):
        with patch.object(self.module.subprocess, "run") as command:
            command.return_value.returncode = 1
            command.return_value.stdout = "PRIVATE"
            with self.assertRaises(ValueError) as error:
                self.module.aws("lambda", "get-function-configuration")
            self.assertNotIn("PRIVATE", str(error.exception))
            command.return_value.returncode = 0
            command.return_value.stdout = '{"State":"Active"}'
            self.assertEqual({"State": "Active"}, self.module.aws("lambda", "get-function-configuration"))
        with trusted_temp_directory() as directory:
            path = directory / "inputs.json"
            path.write_text(json.dumps(self.inputs), encoding="utf-8")
            with patch.object(self.module, "verify"):
                self.assertEqual(0, self.module.main([str(path)]))
            with patch.object(self.module, "verify", side_effect=ValueError("PRIVATE")), redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(2, self.module.main([str(path)]))
            self.assertNotIn("PRIVATE", errors.getvalue())
