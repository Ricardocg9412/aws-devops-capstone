# ECR and publishing / EKS identities

Uses the existing module template (`provider.tf`, `variables.tf`, `locals.tf`,
`main.tf`, `outputs.tf`). Requires Terraform >= 1.9 and AWS provider ~> 6.0.
The caller configures the provider and supplies project/environment naming and
mandatory tags. No credentials, deployment account IDs, or environment-specific
ARNs are embedded in the implementation.

## Repository

- Name: `<name_prefix>-ecr`, for example `inventory-api-dev-ecr`.
- Private ECR repository with immutable image tags. A publisher cannot replace an
  existing tag. Publish unique `sha-<commit>` tags or deploy by digest; do not
  repeatedly push a moving `latest` tag. Retrying an already-published commit
  should reuse the existing digest or use a new unique version tag.
- Basic scan-on-push is enabled using the repository scanning configuration.
  This assumes the account uses ECR BASIC scanning; registry-wide ENHANCED
  scanning/Inspector must be managed centrally if selected instead. This module
  does not change account-wide scanning settings. Scanning detects findings; it
  does not block a push or enforce a deployment vulnerability threshold.
- KMS encryption uses the AWS-managed ECR KMS key (`aws/ecr`); no customer key ARN
  is required. Provisioning needs the applicable ECR/KMS permissions. A customer
  managed key and its policy can be added if required by a later compliance task.
- Lifecycle rule 1 expires untagged images seven days after image push. Rule 2
  retains the newest 30 images matching `sha-*` and expires older matching
  images. Both thresholds are configurable positive integers.
- Images with only non-SHA tags are outside the tagged cleanup rule. An image
  carrying both a `sha-*` tag and a release tag is still eligible for cleanup.
  ECR lifecycle policies do not know which images Kubernetes currently uses:
  size retention for rollback needs and preview rules before production use.
- `force_delete=false` protects a populated repository from forced deletion.
  An appropriately privileged administrator can still delete tags/images; tag
  immutability is not a substitute for IAM restrictions or backup/retention.

## Three separate IAM identities

| Role suffix | Trusted identity | Permissions |
| --- | --- | --- |
| `github-publisher` | GitHub OIDC, exact audience and subject | ECR login and upload actions scoped to this repository |
| `eks-cluster` | `eks.amazonaws.com` in the standard partition | `AmazonEKSClusterPolicy` |
| `eks-node` | `ec2.amazonaws.com` in the standard partition | `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryPullOnly` |

AWS-managed policy ARNs use the detected AWS partition. The publisher's only
wildcard resource statement is `ecr:GetAuthorizationToken`, which does not
support repository-scoped resources. Upload permissions have the repository ARN
as their resource. The publisher cannot create repositories, delete images,
change lifecycle/tag settings, pass IAM roles, or deploy to Kubernetes through
this policy. Additional IAM policies outside this module can change effective
permissions and must be reviewed independently.

The node role intentionally has no publishing permissions. Its managed pull
policy supports EKS add-on image pulls as well as application images, so it is
not restricted to this application's repository. The cluster role is not reused
as a node or CI role.

The optional EKS module consumes these roles for a standard cluster and managed
node group. This ECR module itself does not create EKS, access entries, Pod
Identity/IRSA roles, or a self-managed EC2 instance profile. The EKS module
defines dedicated VPC CNI IRSA permissions rather than adding them to every
node. Application AWS permissions still belong on separate workload roles.
This is not an EKS Auto Mode IAM configuration.

## OIDC trust

Trust uses `StringEquals` for both:

```text
token.actions.githubusercontent.com:aud = sts.amazonaws.com
token.actions.githubusercontent.com:sub = repo:OWNER/REPO:ref:refs/heads/main
```

Setting `github_environment` changes the subject to
`repo:OWNER/REPO:environment:ENVIRONMENT`. These modes are alternatives:
GitHub environment-based subjects do not also contain a branch. Configure
GitHub environment deployment branch restrictions and required reviewers to
control which workflows can use that environment. Environment names containing
colons or percent encoding are intentionally unsupported here.

For repositories using GitHub's immutable OIDC subjects, set
`github_subject_repository = "OWNER@OWNER_ID/REPO@REPO_ID"`. The names must match
`github_repository`; the numeric IDs must match the actual repository/owner.
This produces an exact ID-bearing subject while preserving the chosen branch
or environment. GitHub documents ID-bearing claims for repositories created
after July 15, 2026 or opted into that format. Check the repository's OIDC subject
configuration before first use; a mismatch fails closed. Custom subject templates
outside these formats are not supported. Never widen trust to solve a mismatch.

OIDC provider creation defaults to enabled. There is normally one provider for
`token.actions.githubusercontent.com` per AWS account: if it already exists,
pass `github_oidc_provider_arn` from its owning stack. Do not create it from
multiple environment states. The existing provider must be in the role's
account and include the `sts.amazonaws.com` audience. AWS validates GitHub using
its trusted CA mechanism; no static certificate thumbprint is embedded.

### Why wildcard repository/branch trust is dangerous

An OIDC token proves that GitHub issued it, not that the workflow belongs to
this project. Trusting every repository would let an attacker run a workflow in
their own repository, obtain a valid GitHub token, and assume the publishing
role. Trusting every branch of this repository can expose publishing to
unreviewed branches or other unintended workflow contexts. An attacker could
publish malicious new image tags and compromise the software supply chain;
immutability only prevents replacing existing tags, not publishing new ones.
Exact repository and branch/environment subjects, audience checks, protected
branches/environments, and least-privilege permissions address different parts
of this risk. Trusting a branch allows any eligible workflow on that branch;
protect workflow changes and avoid executing untrusted code in publishing jobs.

## Inputs

| Input | Type | Default | Purpose |
| --- | --- | --- | --- |
| `name_prefix` | string | Required | Project/environment prefix, up to 45 characters |
| `tags` | map(string) | Required | Nonempty Project, Environment, ManagedBy, Owner |
| `github_repository` | string | Required | Exact case-sensitive OWNER/REPO, no wildcards |
| `github_branch` | string | `main` | Exact branch used when environment is null |
| `github_environment` | string | `null` | Exact protected GitHub environment instead of branch |
| `github_subject_repository` | string | `null` | Optional immutable OWNER@ID/REPO@ID subject identity |
| `github_oidc_provider_arn` | string | `null` | Existing account provider; null creates one |
| `untagged_expiration_days` | number | `7` | Positive whole days since push |
| `retained_sha_images` | number | `30` | Positive whole count for sha-* images |

## Outputs

| Output | Purpose |
| --- | --- |
| `repository_name` | Repository name for ECR API calls |
| `repository_arn` | Repository ARN for policies |
| `repository_url` | Registry/repository URL for Docker tags |
| `github_actions_role_arn` | Role for GitHub credential configuration |
| `github_oidc_provider_arn` | Created/reused provider ARN |
| `github_oidc_subject` | Exact subject to compare with GitHub configuration |
| `eks_cluster_role_arn` | Cluster role, ordered after its policy attachment |
| `eks_node_role_arn` | Node role, ordered after its policy attachments |

The publisher role output also depends on its upload policy attachment.

## Verification and publishing integration

```sh
terraform -chdir=terraform/modules/ecr init -backend=false
terraform -chdir=terraform/modules/ecr validate
terraform -chdir=terraform/modules/ecr test
```

Tests mock the AWS provider. They verify repository settings, lifecycle cleanup,
permission boundaries, exact branch and environment subjects, provider reuse,
immutable subject IDs, and rejected wildcard/invalid inputs. Mocked apply only
resolves resource attributes; it does not provision anything or prove live STS
trust, KMS grants, image scanning, or Kubernetes connectivity.

In a future GitHub publishing workflow, grant `contents: read` and
`id-token: write`, obtain temporary AWS credentials using the role ARN output,
and build/push to the repository URL output with a unique `sha-<commit>` tag.
Use the exact trusted branch or protected environment. The job needs no
long-lived AWS access keys. Creating GitHub workflows and publishing images are
outside this Terraform change.

Sources: [GitHub OIDC on AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws),
[ECR push permissions](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-push-iam.html),
[ECR basic scanning](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning-basic-enabling.html),
[EKS cluster role](https://docs.aws.amazon.com/eks/latest/userguide/cluster-iam-role.html),
and [EKS node role](https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html).
