# Application admission policies

Six policies for `devops-lab`, using the current
`policies.kyverno.io/v1` **NamespacedValidatingPolicy** API. They were tested with
the locally installed Kyverno **1.19.2**. This API avoids the deprecated
`kyverno.io/v1 Policy` format; older Kyverno installations may not support it.

## Scope and behavior

Every policy has `metadata.namespace: devops-lab` and an explicit
`request.namespace == 'devops-lab'` match condition. These are not cluster-wide
policies. `kyverno`, `kube-system`, `default`, and other namespaces are outside
their scope, even when their Pods would violate these rules. No namespace
labels or global policy exceptions are changed.

The policies match CREATE and UPDATE for Pods (including the ephemeral-container
subresource), Deployments, StatefulSets, DaemonSets, ReplicaSets,
ReplicationControllers, Jobs, and CronJobs. Controller Pod templates are checked
directly, so invalid controllers can be rejected before they create Pods. Actual
Pod admission is also checked; a controller is not a bypass. No auto-generation
feature is required. CEL variables select the appropriate Pod spec for each kind.

`validationActions: [Deny]` blocks violations; `failurePolicy: Fail` also fails
closed on evaluation errors. Background evaluation is disabled: these are admission-only policies because
they also validate the pods/ephemeralcontainers subresource. Periodic reporting
cannot list/watch this subresource like normal Pods. Installing a policy does
not terminate existing Pods. Existing workloads are not periodically scanned by this policy set; future
noncompliant updates/replacement Pods can still be blocked.
Review/migrate them before activating Deny enforcement.

| Policy file | Enforced condition |
| --- | --- |
| `require-non-root.yaml` | Effective runAsNonRoot=true and effective runAsUser is not 0 |
| `require-resource-limits.yaml` | Positive CPU and memory limits on every normal and init container |
| `disallow-privileged.yaml` | No privileged container; omission uses Kubernetes' false default |
| `require-read-only-root-filesystem.yaml` | Every container explicitly sets readOnlyRootFilesystem=true |
| `disallow-latest-image-tag.yaml` | Explicit non-latest image tag; missing tags and :latest rejected |
| `restrict-image-registries.yaml` | Image repository belongs to the explicit local-lab allowlist |

Non-root inheritance follows container-over-Pod precedence, preserving explicit
false and UID 0 values rather than hiding them behind truthy defaults. A Pod
non-root setting cannot mask a container override to root. A container's explicit
nonzero UID can override a Pod-level UID. If no UID is specified, runAsNonRoot
still requires the kubelet to verify the image user before running it.

Security and image rules cover normal, init, and ephemeral containers. Resource
limits exclude ephemeral containers because Kubernetes does not permit their
resource settings. Restartable init sidecars still need limits. Pod-level
resource limits alone do not satisfy these per-container rules.

A read-only root filesystem requires the chart's dedicated writable `/tmp`
emptyDir for readiness simulation. These six admission policies supplement the
broader Helm security baseline; they do not enforce every control in that chart.

## Local kind image naming and the allowlist

The node's image cache was inspected: the loaded `inventory-api:1.0` is named
`docker.io/library/inventory-api:1.0`. A kind load does not create a separate
registry named `kind`. The allowlist therefore permits only these repository
spellings, followed by a tag/digest boundary:

- `inventory-api`
- `docker.io/library/inventory-api`
- `index.docker.io/library/inventory-api` (Docker Hub endpoint alias)

It does **not** permit arbitrary Docker Hub images, `inventory-api-evil`, arbitrary
ECR accounts, GHCR, or every `localhost` registry. For ECR or another actual
registry, edit `restrict-image-registries.yaml` to add the exact approved
registry/repository URL, escaping regex dots with `[.]` and preserving the
repository boundary. Never add `.*`, all of Docker Hub, or every AWS account to
make an image pull pass. Re-run the fixtures with approved and lookalike URLs.
Replace the lab exception with your actual production allowlist before reuse.

Both short and qualified lab images must still use explicit non-latest tags.
A tag plus digest is accepted; a digest without a tag is deliberately rejected
because this assignment requires explicit tags. A registry port is not an image
tag: `localhost:5000/inventory-api` fails the tag rule.

Repository matching and tag formatting do not verify signatures, image contents,
local cache availability, or tag immutability. `IfNotPresent` can pull from the
real registry when the image is absent. Load the image first; an optional lab
`image.pullPolicy=Never` can require cached images. Production should use its
approved registry, immutable publication, and reviewed digest/signature controls.

## Run offline policy tests

From the repository root, with Kyverno CLI 1.19.2:

```sh
kyverno test kyverno/tests
```

The CLI is not installed on this workstation, so verification used the matching
official CLI container with the repository mounted read-only:

```sh
docker run --rm -v "$(pwd):/work:ro" -w /work \
  reg.kyverno.io/kyverno/kyverno-cli:v1.19.2 test kyverno/tests
```

This command downloads the CLI image if absent but does not contact Kubernetes,
install policies, or pull the fixture workload images. The fixtures contain
intentionally invalid workloads: **do not apply `kyverno/tests/` to a cluster**.
The matrix covers compliant images, root/inheritance overrides, missing/zero
limits, privileged/writable containers, missing/latest tags, unapproved/lookalike
repositories, registry ports, init/ephemeral containers, namespace skips, and
controller templates. Expected failures must actually fail; expected namespace
skips must skip. Check for unexpected skips or policy compilation errors rather
than relying on an exit code alone.

Verification on 2026-10-23: **252 expected results passed**, including intentional
namespace skips. The rendered dev Helm chart also passed all six applicable
checks (`pass: 6, fail: 0, error: 0`). The six policy objects passed server-side
dry-run; a follow-up query confirmed none were installed in `devops-lab`.

## Validate and activate deliberately

All six definitions have passed the installed webhook's server-side dry-run:

```sh
kubectl --context kind-devops-lab apply --dry-run=server -f kyverno/policies
```

Dry-run validates the policy objects but does not persist them or activate their
enforcement. Review existing `devops-lab` workloads first: the original raw
`k8s/` Deployment lacks some of these controls, while the hardened Helm chart is
the intended workload. To activate later, after that review:

```sh
kubectl --context kind-devops-lab apply -f kyverno/policies
kubectl --context kind-devops-lab get namespacedvalidatingpolicies -n devops-lab
```

Wait until policies report ready before relying on admission rejection. For an
initial observation period, use a reviewed copy with `validationActions: [Audit]`
and examine admission results/reports before switching to Deny. Audit changes
the action, not the disabled background-scan setting. Do not disable or widen namespace
scope as a troubleshooting shortcut. To cover another application namespace,
copy the policies with BOTH namespace metadata and the explicit match condition
updated; keep system/Kyverno namespaces excluded.

After activation, use `kubectl create --dry-run=server -f <single-valid-pod.yaml>`
and a single invalid Pod copied into a temporary file with a unique name in
`devops-lab`; the invalid request should be rejected with the corresponding
policy message. Do not submit the multi-document fixture matrix to live admission.
Admission rules depend on healthy Kyverno webhooks; NetworkPolicy enforcement is
a separate CNI responsibility.

No policies were persisted as part of this repository change. Testing does not
change existing lab workloads or enforce anything in Kyverno/system namespaces.

References: [Kyverno namespaced CEL validation policies](https://kyverno.io/docs/policy-types/validating-policy/)
and [Kyverno CLI](https://kyverno.io/docs/kyverno-cli/reference/kyverno/).

## Live compliant/noncompliant Pod test

[tests/live/README.md](tests/live/README.md) provides two standalone Pod manifests
and step-by-step activation, policy-readiness checks, live server dry-runs,
optional real creation, and cleanup. The compliant Pod uses the loaded lab image
with writable /tmp. The negative Pod intentionally violates all six policies.
Unlike the offline fixture matrix, these two files are designed for individual
live admission checks. The policies in the repository remain **Deny/enforce**,
not Audit; nothing is activated until the policy apply command is run.

## Reporting-readiness error for ephemeral containers

If status says `Policy is not ready for reporting, missing permissions: ...
pods/ephemeralcontainers`, use the current files with
`spec.evaluation.background.enabled: false`. The policies retain admission
validation on Pod creation/update and ephemeral-container injection, with
`validationActions: [Deny]` and `failurePolicy: Fail`. Disabling background does
not put them in Audit mode or remove their admission rules. It does remove
periodic scans of already-existing resources.

Do not grant cluster-admin or blindly add list/watch permissions on a subresource
to silence this error. Periodic assessment of existing Pods is a different
workflow from admission on a Pod subresource. If periodic reporting is required
later, split reporting-capable parent-resource policies from admission-only
subresource policies and test both paths separately.

```sh
kubectl --context kind-devops-lab apply -f kyverno/policies
kubectl --context kind-devops-lab -n devops-lab wait \
  --for=jsonpath='{.status.conditionStatus.ready}'=true \
  namespacedvalidatingpolicies --all --timeout=90s
```
