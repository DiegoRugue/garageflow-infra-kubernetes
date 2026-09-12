# AGENTS.md - GarageFlow Platform Infrastructure

## Scope

This repository owns the GarageFlow Phase 3 platform foundation, private ingress and public edge. The platform root owns Terraform state bootstrap, VPC and subnets, EKS, ECR, SNS, common application secrets, the Secrets Manager VPC endpoint, and an empty HTTP API. The ingress root owns the internal ALB, restricted security groups and worker target registration. The edge root owns API Gateway VPC Link, integrations, authorizer configuration, explicit routes and stage.

It does not own RDS, database credentials, Lambda functions or application workloads. Keep each Terraform root self-contained and do not reference another checkout as a module source. Academy ingress uses explicit private HTTP with NodePort 30080; public HTTPS uses the managed execute-api endpoint. Do not add catch-all routes or expose internal authentication, probes or API documentation.

## Environment and state rules

- `develop` maps only to `homologation`; `main` maps only to `production`.
- Resource names use `garageflow-homologation` or `garageflow-production`.
- Platform state keys are `phase3/{environment}/platform.tfstate`.
- Ingress and edge have separate `phase3/{environment}/ingress.tfstate` and `phase3/{environment}/edge.tfstate` keys. Consumers must validate metadata producer, version, environment, account and network identity.
- `TF_STATE_BUCKET` is the protected bucket input for both Terraform state and `contracts/v1/...` metadata.
- Never commit state, plans, credentials, secret values, generated contracts, or environment-specific `.tfvars` files.
- Terraform tests must use mock providers and run without AWS credentials.

## External work-record policy

Keep plans, study notes, agent reports, audits, review logs, and command transcripts outside this and every other source repository. For the current study workspace, place them under `C:/projects/GarageFlow-study/sdd/`. Repository documentation must remain self-contained and must not link to private work records.

## Required local verification

Run these checks before claiming completion:

```bash
python -m pip install --requirement requirements-test.txt
COVERAGE_FILE=/tmp/garageflow-platform-contract.coverage python -m coverage run --source=scripts --omit="scripts/tests/*" -m unittest discover -s scripts/tests -v
COVERAGE_FILE=/tmp/garageflow-platform-contract.coverage python -m coverage report --fail-under=80
python -m unittest discover -s tests -v
terraform fmt -check -recursive infra
terraform -chdir=infra/bootstrap/state-backend init -backend=false -input=false
terraform -chdir=infra/bootstrap/state-backend validate
terraform -chdir=infra/platform init -backend=false -input=false
terraform -chdir=infra/platform validate
terraform -chdir=infra/platform test
bash -n scripts/deploy-platform.sh scripts/lib/deploy-platform-functions.sh
for root in ingress edge; do
  terraform -chdir="infra/${root}" init -backend=false -input=false
  terraform -chdir="infra/${root}" validate
  terraform -chdir="infra/${root}" test
done
bash -n scripts/deploy-ingress.sh scripts/deploy-edge.sh scripts/deploy-edge-component.sh
```
