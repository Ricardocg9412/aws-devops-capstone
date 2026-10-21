# EKS cluster and managed nodes — definitions only

No infrastructure has been deployed. The dev root calls this module only when
`enable_eks=true`; its default is `false`. This module uses only the AWS provider,
not a Kubernetes/Helm provider that would need a live API connection during
configuration. Requires Terraform >= 1.9 and AWS provider ~> 6.0.

## Configuration decisions

| Setting | Definition |
| --- | --- |
| Cluster name | `<name_prefix>-eks`, e.g. `inventory-api-dev-eks` |
| Kubernetes version | Configurable, default `1.35`; reviewed allowlist: 1.34 and 1.35 |
| Endpoint | Private enabled, public disabled; no public fallback |
| Authentication | EKS `API` mode; explicit STANDARD access entries; creator admin disabled |
| Node group | One EKS managed group, `<name_prefix>-workers` |
| Placement | Both supplied private subnets |
| Capacity | ON_DEMAND, desired 2, minimum 1, maximum 3 |
| Node AMI | EKS-optimized `AL2023_x86_64_STANDARD`, matching cluster version |
| Instance type | `t3.medium` (x86-64), compatible with the selected AMI family |
| Logging | api, audit, authenticator, controllerManager, scheduler; CloudWatch retention 30 days |
| Node storage | Encrypted 20-GiB gp3 root volume |
| Metadata | IMDSv2 required, response hop limit 2 |
| CNI identity | Dedicated IRSA role restricted to kube-system/aws-node |

AWS lists Kubernetes 1.35 as supported, with standard support ending March 27,
2027. This version was selected on October 21, 2026. Recheck availability and
support dates in the target AWS region before deployment; static validation is
not a live support-status check. `STANDARD` upgrade policy avoids opting into
extended support; AWS can auto-upgrade at end of standard support, so schedule
controlled upgrades before that deadline.

## Managed-node AMI strategy

There is no hardcoded `ami-*` ID or launch-template image ID. EKS chooses a
compatible AL2023 x86-64 optimized image for the configured Kubernetes version.
The launch template customizes storage, IMDS, public-IP behavior, and tags while
leaving AMI/bootstrap selection to EKS. No custom security groups or instance
profile are supplied in the template, allowing EKS to attach its cluster SG and
manage the node instance profile. No SSH key or remote-access configuration is
created.

`node_ami_release_version=null` selects the EKS default release at initial
creation. It does not continuously patch existing nodes. Optionally pin an
actual EKS AL2023 release version matching `cluster_version`, then roll forward
through reviewed managed-node updates. An AMI release pin is not an AMI ID.
Managed updates allow at most one unavailable node. Scaling is configurable but
must satisfy `1 <= min <= desired <= max`; Terraform currently owns desired
capacity. Integrating an autoscaler requires an explicit ownership decision.

## Private API administration and authentication

`admin_role_arns` must contain at least one permanent IAM role ARN. Each gets a
STANDARD access entry and a cluster-scoped `AmazonEKSClusterAdminPolicy`
association. Use designated platform administrator/SSO roles, not the GitHub
publisher, control-plane, or worker role. The latter two are rejected by input
validation. Bootstrap creator admin is disabled, and no `aws-auth` ConfigMap is
managed. EKS creates the access entry needed by the managed node role; this
module intentionally does not create a competing node entry.

Access entries authorize identities; they do not provide a network path. An
administrator needs all of:

1. Permission to assume an explicitly registered admin role and call
   `eks:DescribeCluster` for kubeconfig generation.
2. Private connectivity to the cluster VPC through VPN/Direct Connect, a routed
   connected network, or an SSM-managed administration host inside the VPC.
3. Working DNS resolution for the private EKS endpoint and HTTPS allowed by the
   administration host's outbound rules, route tables, NACLs, and endpoint SG.
4. An applicable `admin_access_cidrs` entry for the source network (use the actual
   source seen by the cluster SG). CIDRs are /16 or narrower; world-open access
   is rejected. The default empty set adds no external administrative ingress.

The module adds only TCP 443 ingress from approved administrative CIDRs to the
EKS-created cluster SG. EKS itself manages its standard node/control-plane
communication rules. This is not a complete custom least-privilege replacement
for that AWS-managed SG. Do not attach the earlier network module's restrictive
baseline workload SG as a substitute without defining all required EKS rules.

After a future approved deployment, on a host with that private connectivity:

```sh
aws eks update-kubeconfig --region <region> --name <cluster-name> --role-arn <admin-role-arn>
kubectl get nodes
```

Running this from an ordinary internet-connected laptop will not reach the
private API. A hosted GitHub runner cannot use kubectl directly without private
network connectivity either; its existing publisher role grants no cluster
access. IAM recovery operators with EKS access-entry management permissions can
repair entries through the AWS management API without reaching the Kubernetes
API. No VPN, SSM host, or administrative role is provisioned by this module.

## Worker public-IP guard

The module reads each supplied subnet through `data.aws_subnet.worker`.
A node-group lifecycle precondition requires every subnet to have
`map_public_ip_on_launch=false` and to belong to the expected VPC. This is a
blocking precondition, not a warning-only Terraform check. It runs during plan
when the subnet values are known, or before node-group creation when subnets
are created in the same operation and reads are deferred.

The launch template independently sets `associate_public_ip_address=false`.
A negative mocked test sets one subnet's flag to true and expects the node-group
precondition to fail. Another rejects a subnet from another VPC. The dev root
passes only the network module's private subnet IDs. A false auto-IP flag alone
does not prove a subnet has no IGW route; the root's routing design supplies that
additional guarantee. Out-of-band AWS changes still require drift detection.

## CNI and private-network dependencies

The dedicated cluster OIDC provider and VPC CNI role are separate from GitHub's
OIDC provider and publishing role. Its exact trust subject is
`system:serviceaccount:kube-system:aws-node`, audience `sts.amazonaws.com`.
`AmazonEKS_CNI_Policy` is attached to this role, not the worker role. The EKS
`vpc-cni` managed add-on is associated with it before managed workers are created.
Initial conflict resolution adopts/overwrites the default self-managed CNI;
subsequent changes preserve custom settings. AWS selects a compatible add-on
version at creation; assess add-on version upgrades explicitly before production
cluster upgrades. CoreDNS and kube-proxy remain EKS-bootstrap self-managed
add-ons; their ongoing management is outside this module.

The lab still has NAT disabled and no AWS service endpoints. Do not treat
`enable_eks=true` as sufficient for a successful deployment: private nodes/CNI
need reachable ECR API/DKR, S3 image layers, EC2, and regional STS (IRSA), plus
services used by other add-ons/workloads. Provide the NAT/endpoints design from
the network module README before deployment. The private Kubernetes endpoint is
separate from an `eks` management API interface endpoint. OIDC provider creation
and other provisioning calls also need access from the Terraform runner.

## Secrets and KMS tradeoffs

For Kubernetes 1.28+, EKS provides default envelope encryption of Kubernetes API
data, including Secrets, with an AWS-owned KMS key. Leaving
`secrets_kms_key_arn=null` uses this managed behavior; it does not disable secrets
encryption. This is distinct from TLS in transit and the encrypted worker EBS
volume. API-data encryption does not encrypt application data stored on nodes,
external volumes, databases, or backups.

An optional customer-managed symmetric key can provide customer key policies,
CloudTrail visibility, rotation control, and compliance separation. It also
adds key/request costs, permission/grant requirements, and operational risk:
disabling or deleting a required key can make cluster data inaccessible. Supply
a key in the cluster region, with suitable key policy and provisioning grants;
this module neither creates nor manages the lifetime of that key. It does not
verify a key's live region/policy/state during mocked tests.

The Terraform `encryption_config` uses `resources=["secrets"]` for provider/API
compatibility when a customer key is selected. AWS documents that for modern
clusters this legacy field does not limit envelope encryption to Secrets; all
Kubernetes API data is covered. Customer-managed log-group encryption is a
separate configuration and is not provided here; CloudWatch's default at-rest
encryption is used for control-plane logs.

## Inputs

| Input | Type | Default | Meaning |
| --- | --- | --- | --- |
| `name_prefix` | string | Required | Project/environment prefix |
| `cluster_version` | string | `1.35` | Reviewed supported EKS minor version |
| `vpc_id` | string | Required | Expected VPC for subnet validation |
| `private_subnet_ids` | map(string) | Required | Two distinct IDs keyed by AZ |
| `cluster_role_arn` | string | Required | Control-plane IAM role, policies attached |
| `node_role_arn` | string | Required | Managed-node IAM role, policies attached |
| `admin_role_arns` | set(string) | Required | At least one permanent IAM admin role |
| `admin_access_cidrs` | set(string) | `[]` | Approved private API source networks |
| `node_scaling` | object | `{min=1, desired=2, max=3}` | Whole-number scaling settings |
| `node_ami_release_version` | string | `null` | Optional version-compatible EKS AL2023 release pin |
| `secrets_kms_key_arn` | string | `null` | Optional customer-managed key |
| `tags` | map(string) | Required | Project, Environment, ManagedBy, Owner plus extras |

## Outputs

`cluster_name`, `cluster_arn`, `cluster_endpoint`,
`cluster_certificate_authority_data` (public CA certificate, not a private key),
`cluster_security_group_id`, `node_group_name`, `control_plane_log_group_name`,
and `vpc_cni_role_arn`.

## Local verification only

```sh
terraform -chdir=terraform/modules/eks init -backend=false
terraform -chdir=terraform/modules/eks validate
terraform -chdir=terraform/modules/eks test
```

Tests mock all AWS operations, including subnet inspection and simulated resource
creation. They do not contact AWS or deploy infrastructure. They cover private
API settings, access entries, node placement/scaling, logs, encryption settings,
AMI strategy, CNI trust, and rejected public-IP subnet settings/invalid inputs.
They do not prove live node bootstrap, AMI regional availability, private DNS,
IAM/KMS grants, or end-to-end Kubernetes connectivity. No real `apply` is part
of this task.

Sources: [EKS versions](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html),
[private endpoint access](https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html),
[access entries](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html),
[launch templates](https://docs.aws.amazon.com/eks/latest/userguide/launch-templates.html),
[CNI IRSA](https://docs.aws.amazon.com/eks/latest/userguide/cni-iam-role.html),
and [default envelope encryption](https://docs.aws.amazon.com/eks/latest/userguide/envelope-encryption.html).
