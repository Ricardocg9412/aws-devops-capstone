# Mocked Terraform tests

## One-command validation

From the project root:

```sh
./scripts/terraform-validate.sh
```

The script also works when called by its absolute path from another directory.
It accepts no arguments and runs, in order:

1. Recursive `terraform fmt -check` for the whole Terraform tree (no formatting edits).
2. `init -backend=false -input=false -lockfile=readonly` for the dev root.
3. `validate` and `test` for that root.
4. The same initialization, validation, and tests for every directory under
   `terraform/modules`, so module-local acceptance tests are included.

Bash strict mode stops on the first failing command and preserves its nonzero
exit status; later checks and the success message are skipped. Invalid script
arguments return 2, and a missing Terraform executable returns 127. Review and
commit provider lock files before running the script: read-only lock selection
intentionally fails if initialization would require a lock-file update.

### Difference from a real AWS plan

Backend initialization is disabled, so this script does not initialize, migrate,
read, or lock remote state. Provider/module installation may still contact the
Terraform registry; this is not a guaranteed offline command. `validate` checks
configuration and provider schemas, not live AWS permissions or service status.
All current test files explicitly mock AWS. Even test runs using `command=apply`
simulate resources rather than deploy them, and tests use separate temporary
state rather than the root's real state. Keep future tests mocked to preserve
this behavior; the script does not rewrite or sandbox test definitions.

A real `terraform plan` against AWS normally initializes the intended backend,
uses real credentials, reads existing state and AWS data/resources, detects drift,
and proposes changes. It can fail on IAM permissions, region availability,
quotas, networking, or missing dependencies that mocked tests cannot verify.
Planning does not apply infrastructure changes, but it can access and lock state.
This script never invokes a standalone real `plan` or `apply` and is not evidence
that the configuration is ready for deployment. EKS stays disabled by default.

## Individual suites

Run from the project root with Terraform >= 1.9. Tests require the AWS provider
plugin to be installed, but no AWS credentials, running cluster, Docker, or AWS
infrastructure. Initialization may download the locked provider version.

```sh
terraform -chdir=terraform/modules/network init -backend=false
terraform -chdir=terraform/modules/ecr init -backend=false

terraform -chdir=terraform/modules/network test
terraform -chdir=terraform/modules/ecr test
```

Both suites declare `mock_provider "aws"`. Existing mocked-apply tests resolve
computed IDs to check references; the new requirement-specific tests all use
`command=plan`. Neither mode calls real AWS APIs with the mocked provider.

To run only the six required positive conditions and two new negative cases:

```sh
terraform -chdir=terraform/modules/network test -filter=tests/requirements.tftest.hcl
terraform -chdir=terraform/modules/ecr test -filter=tests/requirements.tftest.hcl
```

| Condition | Module | Named run in tests/requirements.tftest.hcl |
| --- | --- | --- |
| VPC CIDR equals the supplied nondefault value | network | `vpc_cidr_matches_configured_value` |
| Exactly two public and two private subnets | network | `exactly_two_public_and_two_private_subnets` |
| Private subnets disable public-IP assignment | network | `private_subnets_disable_public_ip_assignment` |
| All four required tags on taggable resources | network | `mandatory_tags_on_all_tagged_network_resources` |
| ECR image tags are immutable | ecr | `ecr_image_tags_are_immutable` |
| Exact approved GitHub repository and branch | ecr | `github_oidc_trust_matches_approved_repository_and_branch` |
| Invalid leading-zero CIDR prefix is rejected | network | `reject_noncanonical_cidr_prefix` |
| Repository missing its owner is rejected | ecr | `reject_repository_without_owner` |

The mandatory-tag test includes VPC, IGW, both subnet classes, route tables,
security groups, and optional NAT Gateways/EIPs. Routes and associations do not
support tags. The ECR immutability run also checks tags on the repository and all
three IAM roles. Trust is compared against the complete expected policy, so an
extra allow statement, wildcard subject, or wrong repository/branch fails it.

The ECR suite explicitly mocks `aws_partition.partition` and `dns_suffix`. Its
plan-only trust test supplies a fictional existing OIDC provider ARN, avoiding
unknown computed provider ARNs while keeping trust JSON inspectable at plan
time. This is a test fixture, not a hardcoded deployment account. Broader ECR
tests separately cover creation of the OIDC provider and environment-based
trust. No simulated policy or resource is deployed.

The negative cases use `expect_failures=[var.<input>]`. They pass only when the
specified input validation rejects the supplied value; unrelated Terraform
errors still fail the tests. Existing suites include additional negative cases.

Other mocked suites can be run independently:

```sh
terraform -chdir=terraform/modules/eks init -backend=false
terraform -chdir=terraform/modules/eks test
terraform -chdir=terraform/environments/dev init -backend=false
terraform -chdir=terraform/environments/dev test
```

A successful mocked test run verifies configuration logic, not live AWS IAM
trust, image scanning, network connectivity, or node bootstrap. Do not run a
real `terraform apply` to execute these tests.
