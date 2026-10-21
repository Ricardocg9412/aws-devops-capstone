# Network module

Reusable two-AZ IPv4 network for a future EKS cluster. Requires Terraform >= 1.9
and AWS provider ~> 6.0. Configure the AWS provider in the calling root.
This module creates networking only; it does not create EKS, nodes, IAM roles,
VPC endpoints, load balancers, or application infrastructure.

## Default lab topology

| Resource | AZ A (`us-east-1a`) | AZ B (`us-east-1b`) |
| --- | --- | --- |
| VPC | `10.20.0.0/16` (shared) | `10.20.0.0/16` (shared) |
| Public subnet | `10.20.1.0/24` | `10.20.2.0/24` |
| Private subnet | `10.20.11.0/24` | `10.20.12.0/24` |
| Public routing | Shared route table: `0.0.0.0/0` to IGW | Same public table |
| Private routing, NAT off | Local VPC route only | Local VPC route only |
| Private routing, NAT on | `0.0.0.0/0` to NAT in AZ A | `0.0.0.0/0` to NAT in AZ B |

DNS resolution and DNS hostnames are enabled. All four subnets disable automatic
public IP assignment. The public subnets are public because their route table
has an IGW route; an EC2 instance would still need an explicitly assigned public
address to use that route. NAT Gateways receive EIPs when enabled.

Public subnets carry `kubernetes.io/role/elb=1`; private subnets carry
`kubernetes.io/role/internal-elb=1` for load balancer discovery. A cluster-specific
ownership tag is not set because no cluster exists yet. Check controller-specific
requirements when choosing an EKS/controller version.

## Inputs

| Input | Type | Default | Contract |
| --- | --- | --- | --- |
| `name_prefix` | `string` | Required | 1-45 lowercase letters/digits/hyphens, starting with a letter |
| `vpc_cidr` | `string` | Required | Canonical private IPv4 network, /16 through /24 |
| `availability_zones` | `list(string)` | Required | Exactly two distinct standard AZ names, ordered A then B |
| `enable_nat_gateway` | `bool` | `false` | Create two NAT Gateways, EIPs, and private default routes |
| `tags` | `map(string)` | Required | Nonempty Project, Environment, ManagedBy, Owner plus optional tags |

The caller must supply AZs available in its AWS account and provider region.
The dev root checks region consistency; mocked tests cannot prove AWS AZ
availability. The AZ list order defines the CIDR allocation. Keep it stable:
reordering the AZs or changing the parent CIDR changes subnet addresses and can
replace subnets and dependent infrastructure.

Subnet prefix length is `min(parent_prefix + 8, 28)`. Public indices are 1 and 2;
private indices are 11 and 12. For the default /16 these give the assignment's
/24s. Four distinct indices with equal prefix lengths guarantee non-overlap
within the VPC. For a /24 parent, /28 subnets still fit; that small configuration
is supported for validation/reuse but is not recommended for EKS capacity.
This scheme does not detect overlap with other VPCs or connected networks.

## Outputs

| Output | Meaning |
| --- | --- |
| `vpc_id` | VPC ID |
| `vpc_cidr` | VPC CIDR |
| `public_subnet_ids` | Map of AZ to public subnet ID |
| `private_subnet_ids` | Map of AZ to private subnet ID for EKS nodes |
| `public_subnet_cidrs` | Map of AZ to public CIDR |
| `private_subnet_cidrs` | Map of AZ to private CIDR |
| `public_route_table_id` | Shared public route table ID |
| `private_route_table_ids` | Map of AZ to private route table ID for future endpoints |
| `nat_gateway_ids` | Map of AZ to NAT Gateway ID; empty when disabled |
| `workload_security_group_id` | Baseline workload security group ID |

Every explicitly tagged resource receives the caller's tags and, where
appropriate, a consistent Name tag. The provider's root-level defaults also
apply to supported resources. Routes and associations do not support tags.

## Security groups

The VPC default security group is managed with no ingress or egress. A separate
baseline workload group has no ingress and allows only outbound TCP 443.
There is no SSH, public application ingress, or unrestricted all-protocol rule.
Security groups are stateful, so response traffic is allowed. HTTPS egress to
`0.0.0.0/0` permits public registries/APIs when routes exist; it does not create
connectivity or restrict destination domain names.

The workload group is a foundation, not a complete EKS node/control-plane
security group. The future EKS module must add narrowly scoped group-to-group
control-plane, node, and workload rules based on its configuration. The default
Amazon-provided DNS resolver is used; custom DNS resolvers require explicit
UDP/TCP 53 rules. Interface endpoints will need a security group allowing TCP
443 from the actual node/pod security groups and suitable endpoint policies.

## Production egress decision: endpoints plus per-AZ NAT

For a general-purpose production cluster, use both:

- Private AWS service endpoints for image pulls, identity, and AWS API traffic.
- One NAT Gateway per AZ for required public registries, package repositories,
  and external application APIs. Each private subnet routes through its local
  AZ's NAT Gateway, avoiding a dependency on another AZ's NAT Gateway.

For a strictly isolated cluster with all dependencies mirrored privately, NAT
can remain disabled after all required endpoints and private connectivity are
configured. Endpoints are not a substitute for arbitrary internet access.
NAT and interface endpoints have ongoing costs; select endpoints according to
services actually used and assess the cost/availability tradeoff.

Private nodes and workloads need these paths:

| Dependency | Private connectivity / requirement |
| --- | --- |
| ECR authentication and registry | `ecr.api` and `ecr.dkr` interface endpoints, private DNS, HTTPS |
| ECR image layers | S3 gateway endpoint associated with both private route tables; suitable endpoint/IAM policies |
| Kubernetes API | Enable the EKS cluster's private API endpoint and appropriate control-plane/node SG rules; this is separate from an EKS management interface endpoint |
| VPC CNI / EC2 API | `ec2` interface endpoint when no NAT path exists |
| IRSA | Regional `sts` interface endpoint and SDK regional endpoint configuration |
| EKS Pod Identity | `eks-auth` interface endpoint |
| CloudWatch log delivery | `logs` interface endpoint when enabled |
| Load Balancer Controller | `elasticloadbalancing`, plus relevant EC2/STS access |
| Cluster Autoscaler | `autoscaling`, plus relevant EC2/STS access |
| Optional SSM management | Required SSM-related endpoints for the selected agent/features |
| EKS management tooling | `eks` interface endpoint if management API calls originate from isolated clients |
| Public registries / external APIs | NAT or an approved proxy; alternatively mirror images into private ECR |

Enable private DNS for interface endpoints and keep VPC DNS enabled. Bootstrap
must have the required cluster metadata and reachable dependencies; nodes also
need IAM permissions, which endpoints alone do not grant. IAM/OIDC provisioning
may require access to the cluster's issuer discovery URL from the provisioning
client. Endpoint selection depends on enabled add-ons and workload features.

**Implemented now:** optional NAT routing, disabled by default. **Not implemented:**
VPC endpoints and EKS-specific rules. With NAT off and no endpoints, private
subnets cannot pull ECR images or call public AWS APIs. This is intentional for
the local lab; it is not a deployable fully private EKS cluster yet.

Sources: [AWS private-cluster requirements](https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html),
[EKS API endpoint behavior](https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html),
and [subnet discovery tags](https://docs.aws.amazon.com/eks/latest/userguide/tag-subnets-auto.html).

## Validation and tests

From the repository root:

```sh
terraform -chdir=terraform/modules/network init -backend=false
terraform -chdir=terraform/modules/network validate
terraform -chdir=terraform/modules/network test
```

All test providers are mocked. Topology tests use mocked apply to resolve IDs
and verify route/association references without AWS resources. Other cases cover
NAT enablement, smaller VPCs, malformed/host-bit/public/IPv6 CIDRs, invalid AZs,
and missing tag content. Real AWS provisioning and EKS connectivity are not
verified by mocked tests.
