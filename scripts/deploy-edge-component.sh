#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

component="${1:-}"
[[ "${component}" == ingress || "${component}" == edge ]] || { echo 'Unsupported component.' >&2; exit 1; }
for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION TF_STATE_BUCKET EXPECTED_AWS_ACCOUNT_ID DEPLOY_ENVIRONMENT TF_VAR_owner TF_VAR_expires_on GITHUB_REF GITHUB_SHA GITHUB_RUN_ID GITHUB_RUN_ATTEMPT RUNNER_TEMP; do
  [[ -n "${!name:-}" ]] || { echo "Missing protected input: ${name}" >&2; exit 1; }
done
case "${GITHUB_REF}" in
  refs/heads/main) expected_environment=production ;;
  refs/heads/develop) expected_environment=homologation ;;
  *) echo 'Deployment requires main or develop.' >&2; exit 1 ;;
esac
[[ "${DEPLOY_ENVIRONMENT}" == "${expected_environment}" && "${AWS_REGION}" == us-east-1 ]] || { echo 'Branch, environment or region mismatch.' >&2; exit 1; }
[[ "${EXPECTED_AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ && "${GITHUB_SHA}" =~ ^[0-9a-f]{40}$ && "${GITHUB_RUN_ID}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT}" =~ ^[0-9]+$ ]] || { echo 'Invalid account or workflow identity.' >&2; exit 1; }
[[ "${TF_STATE_BUCKET}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { echo 'Invalid state bucket.' >&2; exit 1; }
account="$(aws sts get-caller-identity --query Account --output text)"
[[ "${account}" == "${EXPECTED_AWS_ACCOUNT_ID}" ]] || { echo 'Live AWS account mismatch.' >&2; exit 1; }

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="${script_directory}/../infra/${component}"
workspace="$(mktemp -d "${RUNNER_TEMP}/garageflow-${component}.XXXXXX")"
cleanup() { rm -f -- "${workspace}"/*.json "${workspace}"/*.tfplan; rmdir -- "${workspace}"; }
trap cleanup EXIT

producers=(platform)
[[ "${component}" != edge ]] || producers+=(ingress serverless)
arguments=(--component "${component}" --environment "${DEPLOY_ENVIRONMENT}" --account "${account}" --owner "${TF_VAR_owner}" --expires-on "${TF_VAR_expires_on}" --output "${workspace}/inputs.json")
for producer in "${producers[@]}"; do
  version=1
  [[ "${producer}" != ingress ]] || version=2
  aws s3 cp "s3://${TF_STATE_BUCKET}/contracts/v${version}/${DEPLOY_ENVIRONMENT}/${producer}.json" "${workspace}/${producer}.json" --only-show-errors
  arguments+=("--${producer}" "${workspace}/${producer}.json")
done
python "${script_directory}/edge_tfvars.py" "${arguments[@]}"
if [[ "${component}" == edge ]]; then
  python "${script_directory}/edge_preflight.py" "${workspace}/inputs.json"
fi
unset TF_VAR_owner TF_VAR_expires_on
terraform -chdir="${root}" init -reconfigure -input=false \
  -backend-config="bucket=${TF_STATE_BUCKET}" -backend-config="key=phase3/${DEPLOY_ENVIRONMENT}/${component}.tfstate" \
  -backend-config="region=${AWS_REGION}" -backend-config=encrypt=true -backend-config=use_lockfile=true
terraform -chdir="${root}" validate
terraform -chdir="${root}" plan -input=false -var-file="${workspace}/inputs.json" -out="${workspace}/deployment.tfplan"
terraform -chdir="${root}" apply -input=false "${workspace}/deployment.tfplan"

if [[ "${component}" == ingress ]]; then
  # The ALB exists before the application. Target readiness is checked by application deployment.
  aws elbv2 wait load-balancer-available --names "gf-${DEPLOY_ENVIRONMENT}-internal"
  terraform -chdir="${root}" output -json deployment_outputs >"${workspace}/outputs.json"
  python "${script_directory}/infra_contract.py" publish --input "${workspace}/outputs.json" --output "${workspace}/contract.json" \
    --producer ingress --schema-version 2.0 --environment "${DEPLOY_ENVIRONMENT}" --source-commit "${GITHUB_SHA}"
  revision_key="contracts/v2/${DEPLOY_ENVIRONMENT}/ingress/revisions/${GITHUB_SHA}/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.json"
  stable_key="contracts/v2/${DEPLOY_ENVIRONMENT}/ingress.json"
  aws s3api put-object --bucket "${TF_STATE_BUCKET}" --key "${revision_key}" --body "${workspace}/contract.json" --content-type application/json --if-none-match '*' >/dev/null
  aws s3 cp "${workspace}/contract.json" "s3://${TF_STATE_BUCKET}/${stable_key}" --only-show-errors
else
  terraform -chdir="${root}" output -raw api_url
fi
echo "${component} deployment completed for ${DEPLOY_ENVIRONMENT}."
