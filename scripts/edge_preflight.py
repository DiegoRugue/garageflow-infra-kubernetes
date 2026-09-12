#!/usr/bin/env python3
"""Verify deployed Lambda aliases and application targets before exposing routes."""

import json
import subprocess
import sys

from infra_contract import _resolve_artifact_path


def aws(*arguments):
    result = subprocess.run(["aws", *arguments, "--output", "json"], capture_output=True, text=True, check=False, timeout=60)
    if result.returncode:
        raise ValueError("AWS prerequisite lookup failed")
    return json.loads(result.stdout)


def verify(inputs, cloud=aws):
    platform, ingress, serverless = (inputs[f"{key}_contract"]["outputs"] for key in ("platform", "ingress", "serverless"))
    for name in ("customerAuthenticationAliasArn", "requestAuthorizerAliasArn"):
        function = cloud("lambda", "get-function-configuration", "--function-name", serverless[name])
        settings = function.get("Environment", {}).get("Variables", {})
        if function.get("State") != "Active" or function.get("LastUpdateStatus") != "Successful" or settings.get("JWT_SECRET_ARN") != platform["jwtSecretArn"]:
            raise ValueError("Lambda alias is not ready for the current platform contract")
        if name == "customerAuthenticationAliasArn":
            vpc = function.get("VpcConfig", {})
            if (settings.get("INTERNAL_AUTH_SECRET_ARN") != platform["internalAuthSecretArn"]
                    or settings.get("INTERNAL_API_BASE_URL") != ingress["internalApiBaseUrl"]
                    or settings.get("INTERNAL_API_TRANSPORT") != ingress["transport"]
                    or vpc.get("VpcId") != platform["vpcId"]
                    or set(vpc.get("SubnetIds", [])) != set(platform["privateApplicationSubnetIds"])
                    or set(vpc.get("SecurityGroupIds", [])) != {ingress["authenticationSecurityGroupId"]}):
                raise ValueError("Authentication alias uses stale platform or ingress metadata")
    listener = cloud("elbv2", "describe-listeners", "--listener-arns", ingress["listenerArn"])["Listeners"][0]
    actions = listener["DefaultActions"]
    if len(actions) != 1 or actions[0]["Type"] != "forward" or not actions[0].get("TargetGroupArn"):
        raise ValueError("Application listener does not have one forwarding target")
    targets = cloud("elbv2", "describe-target-health", "--target-group-arn", actions[0]["TargetGroupArn"])["TargetHealthDescriptions"]
    if not targets or any(target["TargetHealth"]["State"] != "healthy" for target in targets):
        raise ValueError("Application must have healthy registered targets before edge deployment")


def main(arguments=None):
    try:
        path, = sys.argv[1:] if arguments is None else arguments
        verify(json.loads(_resolve_artifact_path(path).read_text(encoding="utf-8")))
        return 0
    except (ValueError, KeyError, IndexError, TypeError, OSError, subprocess.SubprocessError):
        print("Edge deployment blocked: aliases or application targets do not match current prerequisites.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
