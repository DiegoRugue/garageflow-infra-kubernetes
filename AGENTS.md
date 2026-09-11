# AGENTS.md - GarageFlow Platform Infrastructure

## Scope

This repository owns the GarageFlow Phase 3 platform foundation: Terraform state bootstrap, VPC and subnets, EKS, ECR, SNS, common application secrets, the Secrets Manager VPC endpoint, and an empty HTTP API.

It does not own RDS, database credentials, Lambda functions, application workloads, ingress/TLS, API Gateway routes, integrations, or authorizers. Keep each Terraform root self-contained and do not reference another checkout as a module source.

## Environment and state rules

- `develop` maps only to `homologation`; `main` maps only to `production`.
- Resource names use `garageflow-homologation` or `garageflow-production`.
- Platform state keys are `phase3/{environment}/platform.tfstate`.
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
```
