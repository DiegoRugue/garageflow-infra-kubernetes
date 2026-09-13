#!/usr/bin/env python3
"""Protected New Relic installation; ingestion credentials travel only through stdin."""

import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

from infra_contract import validate_contract

ROOT = Path(__file__).resolve().parents[1]
CHART_VERSION = "0.14.2"
CHART_SHA256 = "f7bb3f934d0ab01b1c2700237b495644512728a8d04da79abc2fac0262cb9122"
CHART_URL = f"https://github.com/newrelic/helm-charts/releases/download/nr-k8s-otel-collector-{CHART_VERSION}/nr-k8s-otel-collector-{CHART_VERSION}.tgz"
LEASE_NAME = "garageflow-observability-access.json"
RELEASE = "garageflow"
NAMESPACE = "newrelic"


class DeploymentError(RuntimeError):
    """Safe error with no external output or credential payload."""


def run(arguments, payload=None, timeout=120):
    # Even errors from kubectl can repeat an entire Secret. Never forward child output.
    child_environment = {key: value for key, value in os.environ.items() if key != "NEW_RELIC_LICENSE_KEY"}
    try:
        result = subprocess.run(arguments, input=payload, text=True, capture_output=True,
                                env=child_environment, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise DeploymentError(f"{arguments[0]} could not complete") from None
    if result.returncode:
        raise DeploymentError(f"{arguments[0]} command failed; inspect protected resource status")
    return result.stdout


def aws(*arguments):
    return json.loads(run(["aws", *arguments, "--output", "json", "--cli-connect-timeout", "10", "--cli-read-timeout", "30"]))


def validate_inputs(values):
    expected = {"refs/heads/main": "production", "refs/heads/develop": "homologation"}.get(values.get("GITHUB_REF"))
    if expected is None or values.get("DEPLOY_ENVIRONMENT") != expected:
        raise DeploymentError("Deployment requires the matching main/develop protected environment")
    for field, pattern in [("NEW_RELIC_ACCOUNT_ID", r"[1-9][0-9]{0,14}"),
                           ("EXPECTED_AWS_ACCOUNT_ID", r"[0-9]{12}"),
                           ("TF_STATE_BUCKET", r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]")]:
        if not re.fullmatch(pattern, values.get(field, "")):
            raise DeploymentError(f"Invalid protected input: {field}")
    if values.get("NEW_RELIC_REGION") != "US" or values.get("AWS_REGION") != "us-east-1":
        raise DeploymentError("This installation requires New Relic US and AWS us-east-1")
    if not values.get("NEW_RELIC_LICENSE_KEY", "").strip():
        raise DeploymentError("Missing NEW_RELIC_LICENSE_KEY")


def validate_platform(document, values, cluster):
    outputs = validate_contract(document, "platform", values["DEPLOY_ENVIRONMENT"], "1.0")["outputs"]
    account = values["EXPECTED_AWS_ACCOUNT_ID"]
    expected_arn = f"arn:aws:eks:us-east-1:{account}:cluster/{outputs['clusterName']}"
    if (cluster.get("arn") != expected_arn or cluster.get("name") != outputs["clusterName"]
            or cluster.get("resourcesVpcConfig", {}).get("vpcId") != outputs["vpcId"]
            or not outputs["ecrRepositoryUrl"].startswith(f"{account}.dkr.ecr.us-east-1.amazonaws.com/")):
        raise DeploymentError("Platform contract and live AWS cluster identity mismatch")
    return outputs


def download(url, limit=5_000_000):
    with urllib.request.urlopen(url, timeout=30) as response:
        content = response.read(limit + 1)
    if len(content) > limit:
        raise DeploymentError("Download exceeds the expected size")
    return content


def fetch_chart(workspace):
    content = download(CHART_URL)
    if hashlib.sha256(content).hexdigest() != CHART_SHA256:
        raise DeploymentError("New Relic chart release checksum mismatch")
    path = workspace / "collector.tgz"
    path.write_bytes(content)
    return path


def cluster_config(cluster):
    config = aws("eks", "describe-cluster", "--name", cluster)["cluster"]["resourcesVpcConfig"]
    return {field: config[field] for field in ("endpointPublicAccess", "endpointPrivateAccess", "publicAccessCidrs")}


def same_access_config(left, right):
    """EKS can reorder CIDRs; retain exact comparison of every other setting."""
    return {**left, "publicAccessCidrs": sorted(left["publicAccessCidrs"])} == {
        **right, "publicAccessCidrs": sorted(right["publicAccessCidrs"])
    }


def wait_update(cluster, update_id):
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        status = aws("eks", "describe-update", "--name", cluster, "--update-id", update_id)["update"]["status"]
        if status in ("Successful", "Failed", "Cancelled"):
            return status
        time.sleep(10)
    raise DeploymentError("EKS endpoint update timed out")


def update_access(cluster, config, submitted=None):
    update_id = aws("eks", "update-cluster-config", "--name", cluster,
                    "--resources-vpc-config", json.dumps(config))["update"]["id"]
    if submitted:
        submitted(update_id)
    if wait_update(cluster, update_id) != "Successful":
        raise DeploymentError("EKS endpoint update failed")


def restore_access(temporary):
    marker = temporary / LEASE_NAME
    if not marker.exists():
        return
    lease = json.loads(marker.read_text())
    if set(lease) != {"clusterName", "original", "granted", "pendingUpdate"} or not re.fullmatch(r"garageflow-(production|homologation)", lease["clusterName"]):
        raise DeploymentError("Invalid EKS access lease")
    if lease["pendingUpdate"] == "uncertain":
        raise DeploymentError("EKS update submission outcome is unknown; retain lease for operator reconciliation")
    if lease["pendingUpdate"]:
        wait_update(lease["clusterName"], lease["pendingUpdate"])
    current = cluster_config(lease["clusterName"])
    if same_access_config(current, lease["original"]):
        marker.unlink()
        return
    if not same_access_config(current, lease["granted"]):
        raise DeploymentError("EKS access changed concurrently; refusing to overwrite another owner's configuration")
    def submitted(update_id):
        lease["pendingUpdate"] = update_id
        marker.write_text(json.dumps(lease))
    submitted("uncertain")
    update_access(lease["clusterName"], lease["original"], submitted=submitted)
    marker.unlink()


def grant_access(cluster, temporary):
    restore_access(temporary)
    address = ipaddress.ip_address(download("https://checkip.amazonaws.com", 128).decode("ascii").strip())
    if address.version != 4 or not address.is_global:
        raise DeploymentError("Runner address must be a public IPv4")
    original = cluster_config(cluster)
    networks = original["publicAccessCidrs"] if original["endpointPublicAccess"] else []
    for network in networks:
        parsed = ipaddress.ip_network(network, strict=True)
        if parsed.version != 4 or parsed.prefixlen == 0:
            raise DeploymentError("Existing public EKS endpoint access must be scoped")
    granted = dict(endpointPublicAccess=True, endpointPrivateAccess=True,
                   publicAccessCidrs=list(dict.fromkeys([*networks, f"{address}/32"])))
    marker = temporary / LEASE_NAME
    lease = dict(clusterName=cluster, original=original, granted=granted, pendingUpdate=None)
    marker.write_text(json.dumps(lease))
    if not same_access_config(original, granted):
        def submitted(update_id):
            lease["pendingUpdate"] = update_id
            marker.write_text(json.dumps(lease))
        submitted("uncertain")
        update_access(cluster, granted, submitted=submitted)


def apply_secret(key):
    document = dict(apiVersion="v1", kind="Secret", metadata=dict(name="newrelic-license", namespace=NAMESPACE),
                    type="Opaque", stringData={"licenseKey": key})
    # Server-side apply avoids a last-applied-configuration annotation containing the key.
    run(["kubectl", "apply", "--server-side", "--field-manager=garageflow-observability", "-f", "-"],
        payload=json.dumps(document))


def receiver_service():
    return dict(apiVersion="v1", kind="Service", metadata=dict(name="garageflow-otel", namespace=NAMESPACE),
                spec=dict(type="ClusterIP", selector={"app.kubernetes.io/instance": RELEASE, "component": "deployment"},
                          ports=[dict(name="otlp-http", port=4318, targetPort=4318, protocol="TCP")]))


def install(values, temporary, workspace):
    validate_inputs(values)
    if aws("sts", "get-caller-identity")["Account"] != values["EXPECTED_AWS_ACCOUNT_ID"]:
        raise DeploymentError("Live AWS account mismatch")
    document = json.loads(run(["aws", "s3", "cp", f"s3://{values['TF_STATE_BUCKET']}/contracts/v1/{values['DEPLOY_ENVIRONMENT']}/platform.json", "-", "--only-show-errors"]))
    outputs = validate_contract(document, "platform", values["DEPLOY_ENVIRONMENT"], "1.0")["outputs"]
    cluster = outputs["clusterName"]
    validate_platform(document, values, aws("eks", "describe-cluster", "--name", cluster)["cluster"])
    chart = fetch_chart(workspace)
    settings = json.loads((ROOT / "observability/values.json").read_text())
    settings["cluster"] = cluster
    for item in settings["deployment"]["envs"]:
        if item["name"] == "DEPLOYMENT_ENVIRONMENT":
            item["value"] = values["DEPLOY_ENVIRONMENT"]
        elif item["name"] == "CLUSTER_NAME":
            item["value"] = cluster
    settings_path = workspace / "values.json"
    settings_path.write_text(json.dumps(settings))
    os.environ["KUBECONFIG"] = str(workspace / "kubeconfig")
    try:
        grant_access(cluster, temporary)
        run(["aws", "eks", "update-kubeconfig", "--name", cluster, "--kubeconfig", os.environ["KUBECONFIG"]])
        run(["kubectl", "wait", "--for=condition=Ready", "nodes", "--all", "--timeout=5m"], timeout=330)
        run(["kubectl", "apply", "-f", "-"], payload=json.dumps(dict(apiVersion="v1", kind="Namespace", metadata=dict(name=NAMESPACE))))
        apply_secret(values["NEW_RELIC_LICENSE_KEY"])
        run(["helm", "upgrade", "--install", RELEASE, str(chart), "--namespace", NAMESPACE,
             "--values", str(settings_path),
             "--atomic", "--wait", "--timeout", "10m", "--history-max", "3"], timeout=660)
        run(["kubectl", "apply", "-f", "-"], payload=json.dumps(receiver_service()))
        # A referenced Secret is outside Helm ownership; restart to pick up rotations.
        for kind in ("deployment", "daemonset"):
            run(["kubectl", "rollout", "restart", kind, "-n", NAMESPACE, "-l", "app.kubernetes.io/instance=garageflow"])
            run(["kubectl", "rollout", "status", kind, "-n", NAMESPACE, "-l", "app.kubernetes.io/instance=garageflow", "--timeout=5m"], timeout=330)
    finally:
        restore_access(temporary)


def main():
    os.umask(0o077)
    values = dict(os.environ)
    temporary = Path(values["RUNNER_TEMP"]).resolve(strict=True)
    if sys.argv[1:] == ["cleanup"]:
        restore_access(temporary)
        return
    if values.get("NEW_RELIC_ENABLED", "false") != "true":
        print("New Relic deployment is disabled.")
        return
    with tempfile.TemporaryDirectory(prefix="garageflow-observability-", dir=temporary) as workspace:
        install(values, temporary, Path(workspace))
    print("New Relic collectors installed; ingestion acceptance must be verified separately.")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Network, parse and provider exceptions can contain secrets or response bodies.
        print("Observability deployment failed. Check protected inputs, resource status and EKS access lease cleanup.", file=sys.stderr)
        sys.exit(1)
