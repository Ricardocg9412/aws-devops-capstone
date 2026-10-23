# Live admission test in local kind

The repository policies are in **enforce mode** (`validationActions: [Deny]`),
with evaluation errors failing closed (`failurePolicy: Fail`). They do nothing
until installed. These commands activate them only in `devops-lab`; the
namespace guard excludes system and Kyverno namespaces.

Run from the repository root. First review other workloads in `devops-lab`:
Deny enforcement can block future updates/replacement Pods if they are
noncompliant. Background scans are disabled so subresource admission does not
require reporting/list-watch permissions. No existing Pods are automatically deleted by installing a policy.

## 1. Install and wait for policies

```sh
kubectl --context kind-devops-lab apply -f kyverno/policies
kubectl --context kind-devops-lab -n devops-lab wait \
  --for=jsonpath='{.status.conditionStatus.ready}'=true \
  namespacedvalidatingpolicies --all --timeout=90s
kubectl --context kind-devops-lab -n devops-lab get namespacedvalidatingpolicies
```

This Kyverno version stores readiness under `status.conditionStatus.ready`,
not `status.conditions`. If waiting fails, inspect a policy with
`kubectl --context kind-devops-lab -n devops-lab get namespacedvalidatingpolicy require-non-root -o yaml`
and inspect the Kyverno admission-controller logs before testing.

## 2. Exercise live admission safely

```sh
# Expected: accepted. The webhook evaluates the request, but no Pod is persisted.
kubectl --context kind-devops-lab create --dry-run=server \
  -f kyverno/tests/live/compliant-pod.yaml

# Expected: denied by Kyverno, with nonzero exit status. No Pod is persisted.
kubectl --context kind-devops-lab create --dry-run=server \
  -f kyverno/tests/live/noncompliant-pod.yaml
```

This is live webhook validation, unlike `kyverno test`, which evaluates the
rules locally. Confirm the negative result names the intended Kyverno policies;
a generic YAML/admission error or connection failure is not proof of enforcement.
The negative fixture violates all six policies. Use the individual fixtures in
`../pods.yaml` with isolated fields if you want to inspect one failure at a time.
Do not apply the entire test directory or that multi-document fixture file.

## 3. Actually create the compliant Pod

```sh
kind load docker-image inventory-api:1.0 --name devops-lab
kubectl --context kind-devops-lab create -f kyverno/tests/live/compliant-pod.yaml
kubectl --context kind-devops-lab -n devops-lab wait \
  --for=condition=Ready pod/kyverno-compliant-pod --timeout=90s
kubectl --context kind-devops-lab -n devops-lab exec kyverno-compliant-pod -- \
  python -c 'import os, urllib.request; print("UID:", os.getuid()); print("Health:", urllib.request.urlopen("http://127.0.0.1:8080/health").status)'
```

`imagePullPolicy: Never` deliberately requires the image already loaded on the
kind node. A missing image causes an image-pull/startup error after admission;
that is different from a Kyverno denial. This Pod uses writable /tmp storage
while keeping its root filesystem read-only. It uses a distinct instance label,
so an existing chart Service will not accidentally select this test Pod.

Optionally submit a real creation request for the negative fixture after its
server dry-run was denied:

```sh
kubectl --context kind-devops-lab create -f kyverno/tests/live/noncompliant-pod.yaml
```

Expected: rejected; `kyverno-noncompliant-pod` should not exist. If it is created,
stop and inspect policy readiness/scope/actions instead of treating a subsequent
ImagePullBackOff as successful enforcement.

## 4. Cleanup

```sh
kubectl --context kind-devops-lab -n devops-lab delete pod \
  kyverno-compliant-pod kyverno-noncompliant-pod --ignore-not-found
```

This leaves policies installed. To deliberately disable this policy set:

```sh
kubectl --context kind-devops-lab delete -f kyverno/policies
```

For Audit instead of enforcement, change the policy's `validationActions` from
`[Deny]` to `[Audit]` in a reviewed copy and apply it. Audit permits invalid
requests and records violations; it does not demonstrate rejection. These files
retain Deny mode, and their positive/negative expectations are also covered by
the local CLI test under this directory.
