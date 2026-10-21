# ADR 0001: Terraform state in AWS

Date: 2026-10-21  
Status: Accepted design; implementation deferred

## Context

Real AWS deployments need shared state, serialized writes, and recovery without
exposing infrastructure metadata or credentials. The lab currently uses local
state. No backend resources or backend configuration are created by this ADR.

## Decision

- **S3 backend:** Store state in dedicated, versioned S3 buckets with public
  access blocked and bucket policies requiring TLS. Bootstrap backend resources
  in a separate infrastructure stack before migrating application state; do not
  make an application root responsible for destroying its own backend.
- **Locking:** Use native S3 locking with `use_lockfile=true`. Before adoption,
  raise the backend-using roots' minimum Terraform version from 1.9 to at least
  1.10 and standardize developer/CI versions. Do not introduce deprecated
  DynamoDB locking. Never bypass locking for concurrent operations; force-unlock
  only after confirming the original writer has stopped. Retention rules must
  not prevent deletion of the live `.tflock` object or expire an active lock.
- **Encryption:** Require SSE-KMS with a customer-managed key per environment
  and configure backend encryption explicitly. Limit key use through IAM and key
  policies, enable rotation, and retain keys as long as encrypted state versions
  or backups need recovery. S3 encryption does not protect state after an
  authorized reader downloads it.
- **IAM boundaries:** Use short-lived, separate Terraform execution roles via
  SSO or restricted CI OIDC. Limit bucket listing to the environment's state
  prefix; grant GetObject/PutObject on its state and GetObject/PutObject/
  DeleteObject on its lock file. Ordinary runners do not need state deletion,
  bucket administration, or KMS administration. Grant only necessary KMS data
  operations; reserve historical-version recovery for a recovery role. The
  image-publishing role receives no backend permissions. Production execution
  requires a protected approval path. Audit state-object access with CloudTrail
  S3 data events and monitor KMS use.
- **Environment separation:** Use separate dev/prod AWS accounts, buckets, keys,
  execution roles, and root configurations. Each root owns a distinct state key,
  such as `inventory-api/dev/terraform.tfstate`. Changing `environment` or using
  workspaces alone is not an IAM isolation boundary. Account-global resources,
  such as the GitHub OIDC provider, have one designated owner state.
- **History and recovery:** Enable S3 versioning and retain noncurrent state
  versions for a documented recovery period, initially 90 days. Restrict
  permanent version deletion; use separately protected backups for stronger
  deletion resilience. To recover, stop writers, preserve the current version,
  identify a known-good version, and restore it as a new current version through
  the recovery role. Check state lineage and review a fresh plan against actual
  AWS resources before permitting changes. Restoring state does not roll back
  infrastructure. Test this procedure periodically.

## Consequences and secret handling

State and saved plans may contain plaintext secrets even when values are marked
`sensitive`; that flag primarily redacts presentation. Avoid passing secret
values through Terraform when applications can retrieve them from Secrets
Manager or Parameter Store at runtime. References alone are preferable, but
reading secret values into managed attributes/data sources can still persist
those values. Never commit state/plans or expose them through logs or broadly
readable CI artifacts. Historical versions can retain leaked secrets: rotate
exposed credentials and review retained copies rather than assuming an update
removed the exposure. Cross-stack state readers can access the full snapshot,
not only declared outputs, so publish narrow nonsecret interfaces separately.

This design adds KMS, audit, backup, and IAM administration overhead in exchange
for controlled collaboration and recovery. No AWS resources were provisioned,
no local state was migrated, and the current Terraform constraints are unchanged.

## References

- [HashiCorp: S3 backend, locking, and permissions](https://developer.hashicorp.com/terraform/language/backend/s3)
- [AWS: Terraform backend best practices and native locking requirements](https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/backend.html)
