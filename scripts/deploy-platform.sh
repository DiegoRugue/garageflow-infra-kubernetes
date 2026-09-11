#!/usr/bin/env bash
set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${script_directory}/lib/deploy-platform-functions.sh"

required_variables=(
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  AWS_SESSION_TOKEN
  AWS_REGION
  TF_STATE_BUCKET
  TF_VAR_environment
  TF_VAR_aws_region
  TF_VAR_owner
  TF_VAR_expires_on
  TF_VAR_eks_cluster_role_arn
  TF_VAR_eks_node_role_arn
  TF_VAR_kubernetes_version
  TF_VAR_bootstrap_admin_email
  TF_VAR_notification_email
  TF_VAR_public_access_cidrs
  GITHUB_REF
  GITHUB_SHA
  GITHUB_RUN_ID
  GITHUB_RUN_ATTEMPT
  RUNNER_TEMP
)

missing_variables=()
for variable_name in "${required_variables[@]}"; do
  [[ -n "${!variable_name:-}" ]] || missing_variables+=("${variable_name}")
done
if (( ${#missing_variables[@]} > 0 )); then
  echo "Deployment refused: missing required protected inputs: ${missing_variables[*]}" >&2
  exit 1
fi

case "${GITHUB_REF}" in
  refs/heads/develop)
    expected_environment="homologation"
    ;;
  refs/heads/main)
    expected_environment="production"
    ;;
  *)
    echo "Deployment refused: only develop and main may deploy." >&2
    exit 1
    ;;
esac

[[ "${TF_VAR_environment}" == "${expected_environment}" ]] || {
  echo "Deployment refused: branch and Terraform environment do not match." >&2
  exit 1
}
[[ "${AWS_REGION}" == "us-east-1" ]] || {
  echo "Deployment refused: AWS_REGION must be us-east-1." >&2
  exit 1
}
[[ "${TF_VAR_aws_region}" == "${AWS_REGION}" ]] || {
  echo "Deployment refused: Terraform and AWS regions do not match." >&2
  exit 1
}
[[ "${GITHUB_SHA}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Deployment refused: GITHUB_SHA must be a lowercase 40-character commit SHA." >&2
  exit 1
}
[[ "${GITHUB_RUN_ID}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT}" =~ ^[0-9]+$ ]] || {
  echo "Deployment refused: workflow run identifiers must be numeric." >&2
  exit 1
}
[[ "${TF_STATE_BUCKET}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || {
  echo "Deployment refused: TF_STATE_BUCKET is not a valid S3 bucket name." >&2
  exit 1
}
merged_public_access_cidrs="$(resolve_runner_access_cidrs "${TF_VAR_public_access_cidrs}")" || {
  echo "Deployment refused: the current runner cannot be granted a verified scoped EKS API path." >&2
  exit 1
}
export TF_VAR_public_access_cidrs="${merged_public_access_cidrs}"
echo "Current runner public IPv4 /32 added to the configured EKS access CIDRs."

caller_account="$(aws sts get-caller-identity --query Account --output text)"
[[ "${caller_account}" =~ ^[0-9]{12}$ ]] || {
  echo "Deployment refused: STS did not return a valid AWS account." >&2
  exit 1
}

role_account() {
  local role_arn="$1"
  if [[ "${role_arn}" =~ ^arn:[a-z0-9-]+:iam::([0-9]{12}):role/[A-Za-z0-9+=,.@_/-]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

cluster_role_account="$(role_account "${TF_VAR_eks_cluster_role_arn}")" || {
  echo "Deployment refused: EKS cluster role ARN is invalid." >&2
  exit 1
}
node_role_account="$(role_account "${TF_VAR_eks_node_role_arn}")" || {
  echo "Deployment refused: EKS node role ARN is invalid." >&2
  exit 1
}
[[ "${caller_account}" == "${cluster_role_account}" && "${caller_account}" == "${node_role_account}" ]] || {
  echo "Deployment refused: STS account and EKS role accounts do not match." >&2
  exit 1
}

support_status="$(aws eks describe-cluster-versions \
  --region "${AWS_REGION}" \
  --cluster-versions "${TF_VAR_kubernetes_version}" \
  --query 'clusterVersions[0].versionStatus' \
  --output text)"
[[ "${support_status}" == "STANDARD_SUPPORT" ]] || {
  echo "Deployment refused: requested EKS version is not in STANDARD_SUPPORT." >&2
  exit 1
}

mapfile -t availability_zones < <(
  aws ec2 describe-availability-zones \
    --region "${AWS_REGION}" \
    --filters Name=state,Values=available \
    --query 'sort_by(AvailabilityZones,&ZoneName)[:2].ZoneName' \
    --output text | tr '\t' '\n' | sed '/^$/d'
)
(( ${#availability_zones[@]} == 2 )) || {
  echo "Deployment refused: two available zones are required." >&2
  exit 1
}
for availability_zone in "${availability_zones[@]}"; do
  offering_count="$(aws ec2 describe-instance-type-offerings \
    --region "${AWS_REGION}" \
    --location-type availability-zone \
    --filters Name=instance-type,Values=t3.small Name=location,Values="${availability_zone}" \
    --query 'length(InstanceTypeOfferings)' \
    --output text)"
  [[ "${offering_count}" == "1" ]] || {
    echo "Deployment refused: t3.small is unavailable in a selected availability zone." >&2
    exit 1
  }
done

platform_root="infra/platform"
state_key="phase3/${TF_VAR_environment}/platform.tfstate"
plan_path="${RUNNER_TEMP}/garageflow-${TF_VAR_environment}-platform-${GITHUB_SHA}.tfplan"
outputs_path="${RUNNER_TEMP}/garageflow-${TF_VAR_environment}-platform-outputs.json"
contract_path="${RUNNER_TEMP}/garageflow-${TF_VAR_environment}-platform-contract.json"
trap 'rm -f -- "${plan_path}" "${outputs_path}" "${contract_path}"' EXIT

terraform -chdir="${platform_root}" init \
  -reconfigure \
  -input=false \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${state_key}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
terraform -chdir="${platform_root}" validate
terraform -chdir="${platform_root}" plan -input=false -out="${plan_path}"
terraform -chdir="${platform_root}" apply -input=false "${plan_path}"

cluster_name="$(terraform -chdir="${platform_root}" output -json deployment_outputs | python3 -c 'import json,sys; print(json.load(sys.stdin)["clusterName"])')"
node_group_name="${cluster_name}-workers"
aws eks wait cluster-active --region "${AWS_REGION}" --name "${cluster_name}"
aws eks wait nodegroup-active --region "${AWS_REGION}" --cluster-name "${cluster_name}" --nodegroup-name "${node_group_name}"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${cluster_name}"

wait_for_ready_nodes 600 10 10s

terraform -chdir="${platform_root}" output -json deployment_outputs > "${outputs_path}"
python3 scripts/infra_contract.py publish \
  --input "${outputs_path}" \
  --output "${contract_path}" \
  --producer platform \
  --environment "${TF_VAR_environment}" \
  --source-commit "${GITHUB_SHA}"
python3 scripts/infra_contract.py validate \
  --file "${contract_path}" \
  --producer platform \
  --environment "${TF_VAR_environment}"

revision_key="contracts/v1/${TF_VAR_environment}/platform/revisions/${GITHUB_SHA}/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.json"
stable_key="contracts/v1/${TF_VAR_environment}/platform.json"
aws s3api put-object \
  --bucket "${TF_STATE_BUCKET}" \
  --key "${revision_key}" \
  --body "${contract_path}" \
  --content-type application/json \
  --if-none-match '*' >/dev/null
aws s3api put-object \
  --bucket "${TF_STATE_BUCKET}" \
  --key "${stable_key}" \
  --body "${contract_path}" \
  --content-type application/json >/dev/null

echo "Platform deployment and contract publication completed for ${TF_VAR_environment}."
