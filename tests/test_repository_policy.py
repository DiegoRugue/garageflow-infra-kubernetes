import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
INFRA_ROOT = REPOSITORY_ROOT / "infra"


class RepositoryPolicyTests(unittest.TestCase):
    def terraform_text(self) -> str:
        return "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(INFRA_ROOT.rglob("*.tf"))
            if ".terraform" not in path.parts
        )

    def test_platform_does_not_own_database_resources_or_credentials(self) -> None:
        terraform = self.terraform_text()
        forbidden = (
            'resource "aws_db_instance"',
            'resource "aws_db_subnet_group"',
            'resource "random_password" "database"',
            'resource "aws_secretsmanager_secret" "database"',
            "database_password",
            "databaseSecretArn",
        )

        for token in forbidden:
            with self.subTest(token=token):
                self.assertNotIn(token, terraform)

    def test_only_public_route_table_has_an_internet_default_route(self) -> None:
        network = (INFRA_ROOT / "modules" / "network" / "main.tf").read_text(encoding="utf-8")
        routes = re.findall(r'resource\s+"aws_route"\s+"([^"]+)"\s*\{(.*?)\n\}', network, re.DOTALL)
        default_route_owners = [name for name, body in routes if 'destination_cidr_block = "0.0.0.0/0"' in body]

        self.assertEqual(["public_default"], default_route_owners)
        self.assertNotIn('resource "aws_nat_gateway"', network)

    def test_empty_http_api_has_no_edge_or_compute_resources(self) -> None:
        terraform = self.terraform_text()
        forbidden_resource_types = (
            "aws_apigatewayv2_route",
            "aws_apigatewayv2_integration",
            "aws_apigatewayv2_authorizer",
            "aws_lambda_function",
        )

        for resource_type in forbidden_resource_types:
            with self.subTest(resource_type=resource_type):
                self.assertNotRegex(terraform, rf'resource\s+"{resource_type}"')

    def test_deploy_is_branch_gated_and_publishes_revision_before_stable_contract(self) -> None:
        workflow = (REPOSITORY_ROOT / ".github" / "workflows" / "deploy.yml").read_text(encoding="utf-8")
        script = (REPOSITORY_ROOT / "scripts" / "deploy-platform.sh").read_text(encoding="utf-8")

        self.assertNotRegex(workflow, r"(?m)^\s*pull_request:")
        self.assertIn("github.ref == 'refs/heads/main' || github.ref == 'refs/heads/develop'", workflow)
        self.assertIn("needs: quality-gate", workflow)
        self.assertIn('environment: ${{ github.ref_name == \'main\' && \'production\' || \'homologation\' }}', workflow)
        self.assertIn('state_key="phase3/${TF_VAR_environment}/platform.tfstate"', script)
        self.assertIn('terraform -chdir="${platform_root}" output -json deployment_outputs', script)
        self.assertLess(script.index('--key "${revision_key}"'), script.index('--key "${stable_key}"'))

    def test_modules_and_roots_have_no_cross_checkout_sources(self) -> None:
        checked_paths = [
            *INFRA_ROOT.rglob("*.tf"),
            *REPOSITORY_ROOT.glob("scripts/**/*.sh"),
            *REPOSITORY_ROOT.glob(".github/workflows/*.yml"),
        ]
        source = "\n".join(path.read_text(encoding="utf-8") for path in checked_paths)

        self.assertNotIn(".worktrees", source)
        self.assertNotIn("C:/projects/", source)
        self.assertNotIn("C:\\projects\\", source)


if __name__ == "__main__":
    unittest.main()
