# Root configuration

## Naming and tags

Resource names use `<project_name>-<environment>-<resource-role>`, for example
`inventory-api-dev-vpc`. `local.name_prefix` supplies the project/environment
prefix. Project names contain 1-40 lowercase letters, digits, or hyphens and
start with a letter. Environments are `dev` or `prod`. Future modules must also
respect each AWS resource's specific name limits.

The AWS provider applies `local.resource_tags` as default tags to supported
resources. `common_tags` must contain non-empty `Project`, `Environment`,
`ManagedBy`, and `Owner` values. The root normalizes `Project` to `project_name`,
`Environment` to `environment`, and `ManagedBy` to `terraform`, overriding
conflicting caller values. `Owner` is trimmed; additional tags are preserved.

The network module receives `local.name_prefix` and `local.resource_tags`.
Resource-specific tags must preserve mandatory values: AWS resource-level tags
can override provider defaults. Resources that do not support provider default
tags require explicit handling. This root now calls the network module.

## VPC addressing policy

`vpc_cidr` must be a canonical IPv4 network in RFC 1918 private address space:
`10.0.0.0/8`, `172.16.0.0/12`, or `192.168.0.0/16`. Prefixes must be between
`/16` and `/24`, inclusive. This is a project policy, not the full set of CIDRs
AWS accepts. The default remains `10.20.0.0/16`.

Examples accepted: `10.20.0.0/16`, `172.16.0.0/20`, `192.168.1.0/24`.
Examples rejected: `10.20.0.5/16` (host bits), `10.0.0.0/8` (too broad),
`10.20.0.0/25` (too small), `8.8.0.0/16` (public), and IPv6.
Whitespace, leading-zero octets, and noncanonical prefix notation are rejected.

Validation uses `cidrnetmask` to require valid IPv4, verifies the prefix limits,
compares against `cidrhost(cidr, 0)` plus the normalized prefix to require a
network address, and checks private-range membership. Given the /16 minimum
prefix length, an accepted network cannot extend outside its private range.
An outer `try(..., false)` turns malformed or null input into a validation
failure rather than an expression error.

`can(cidrhost(cidr, 0))` alone is insufficient: it accepts IPv6 and does not
check project prefix limits, host bits, private-range membership, or overlap.
For example, `10.20.1.0/24` and `10.20.1.128/25` are both valid CIDRs but overlap.
Distinct strings do not imply distinct address ranges. Even two separately
valid VPC inputs can overlap, so this rule does not prevent dev/prod collisions.
The network module derives four distinct equal-sized subnets inside the VPC,
using indices 1, 2, 11, and 12. Its subnet prefix is the parent prefix plus eight,
capped at /28. The default /16 produces the required /24 layout. EKS capacity
planning must still account for node and pod IP demand.

References: [cidrnetmask](https://developer.hashicorp.com/terraform/language/functions/cidrnetmask)
and [cidrhost](https://developer.hashicorp.com/terraform/language/functions/cidrhost).

## Validation and tests

From the repository root:

```sh
terraform -chdir=terraform/environments/dev validate
terraform -chdir=terraform/environments/dev test
```

Tests use a mocked AWS provider and perform no AWS operations.

## Network deployment

The root calls [`../../modules/network`](../../modules/network/README.md).
The default VPC is `10.20.0.0/16`, with public `10.20.1.0/24` and
`10.20.2.0/24`, private `10.20.11.0/24` and `10.20.12.0/24`.
NAT is disabled and no VPC endpoints are created. Private subnets therefore
have no outbound path to public AWS APIs or image registries by default.

| Input | Type | Default |
| --- | --- | --- |
| `project_name` | string | `inventory-api` |
| `environment` | string | `dev`; allowed: dev, prod |
| `aws_region` | string | `us-east-1` |
| `vpc_cidr` | string | `10.20.0.0/16` |
| `availability_zones` | list(string) | `["us-east-1a", "us-east-1b"]` |
| `enable_nat_gateway` | bool | `false` |
| `common_tags` | map(string) | Project=inventory-api, Environment=dev, ManagedBy=terraform, Owner=platform-team |

Exactly two distinct AZ names must match `aws_region`. Actual AZ availability
must be verified in the target account. Changing the region also requires
changing the AZ list. Resources use the active AWS credential chain; no account
IDs, credentials, or ARNs are embedded.

Root outputs forward the module's VPC ID/CIDR, public/private subnet ID and CIDR
maps, public/private route table IDs, NAT Gateway ID map, and workload SG ID.
See the module README for each output and the production egress decision.

```sh
terraform -chdir=terraform/environments/dev init -backend=false
terraform -chdir=terraform/environments/dev validate
terraform -chdir=terraform/environments/dev test

# Requires AWS credentials; planning does not create infrastructure
terraform -chdir=terraform/environments/dev plan
# Optional NAT plan: adds two NAT Gateways and associated EIPs/routes
terraform -chdir=terraform/environments/dev plan -var='enable_nat_gateway=true'
```

Apply a reviewed plan only when ready to provision real AWS infrastructure.
Keep `terraform/environments/dev/.terraform.lock.hcl` under version control;
`.terraform/`, state, and saved `.tfplan` files are ignored. Production should use
its own root/state when implemented, not share dev state by changing a variable.
