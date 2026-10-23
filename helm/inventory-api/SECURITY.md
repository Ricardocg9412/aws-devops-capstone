# Runtime security and verification

## Enforced chart baseline

| Control | Rendered setting |
| --- | --- |
| Non-root UID | Pod and container runAsNonRoot=true, runAsUser=10001 |
| Group and volume access | runAsGroup=10001, fsGroup=10001 by default |
| Privileges | privileged=false, allowPrivilegeEscalation=false |
| Capabilities | drop ALL; no added capabilities |
| Root filesystem | readOnlyRootFilesystem=true |
| Seccomp | RuntimeDefault on Pod and container |
| Kubernetes credentials | automountServiceAccountToken=false on Pod and generated ServiceAccount |
| Host namespaces | hostNetwork=false, hostPID=false, hostIPC=false |
| Resources | Positive CPU and memory requests AND limits are mandatory |
| Writable storage | Only /tmp is mounted writable, via a bounded emptyDir |

Security values are visible in `values.yaml`, but the JSON schema rejects
unsafe changes for all profiles: UID 0, another UID, privilege/escalation,
capability additions, writable root, Unconfined seccomp, token automount, and
host namespaces. Container ports must be unprivileged (1024-65535); Service port
80 is still supported. Group IDs, fsGroup behavior, resource sizing, temporary
volume medium/size, and approved network peers can be configured within the
baseline. Admission policy such as Pod Security Admission Restricted should
independently protect production namespaces; chart validation is not a substitute
for cluster enforcement and can be bypassed by users rendering arbitrary YAML.

The provided image is compatible with UID 10001. A replacement image must also
run under that UID, read its application files without root, and place any
required writes in /tmp. Python bytecode writes are disabled explicitly. The
chart does not grant permission to alter files or install packages at runtime.

## Writable readiness simulation

The root stays read-only. An `emptyDir` mounts at `/tmp` with readOnly=false;
fsGroup makes it writable by the application without a privileged init container.
Defaults: medium Memory, sizeLimit 32Mi. Memory-backed writes count toward memory
use; this limit is not a memory reservation. Keep the budget compatible with
Pod memory limits. Disk-backed emptyDir (`medium: ""`) is also supported.

The readiness marker defaults to `/tmp/inventory-api.unready`. It must be a
single filename directly under /tmp; traversal and paths elsewhere are rejected.
An explicit container environment entry prevents a referenced Secret from
moving the marker elsewhere. TMPDIR, bytecode, and bind/port settings are also
chart-managed. The marker survives a container restart within the same Pod but
is lost when the Pod/emptyDir is removed. Remove it to restore readiness.

With a deployed release, select one specific application Pod:

```sh
namespace=devops-lab
pod=$(kubectl -n "$namespace" get pods -l app.kubernetes.io/instance=inventory-api-dev -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$namespace" exec "$pod" -- id

# Expected: nonzero exit and "Read-only file system". /app is image-owned by UID 10001.
kubectl -n "$namespace" exec "$pod" -- python -c 'from pathlib import Path; Path("/app/security-write-probe").write_text("must fail")'

# This write must succeed; /ready now returns 503 while /health stays 200.
kubectl -n "$namespace" exec "$pod" -- touch /tmp/inventory-api.unready
# Direct Pod port-forward deliberately bypasses Service readiness selection.
kubectl -n "$namespace" port-forward pod/"$pod" 8081:8080
```

From another terminal, request `http://127.0.0.1:8081/ready` and `/health`.
Then remove the marker with `kubectl -n "$namespace" exec "$pod" -- rm
/tmp/inventory-api.unready` (one command) and confirm readiness returns 200.
A normal Service stops selecting an unready endpoint after the readiness probe
observes failure. With multiple replicas, requests through the Service may reach
a different healthy Pod, so target the selected Pod for this simulation.

## NetworkPolicy

The mandatory policy selects only this release's application Pods and isolates
both Ingress and Egress. It is not a namespace-wide policy for unrelated workloads.

Default allowances:

- Ingress: TCP on the named application port `http` from Pods in the same
  namespace labeled `inventory-api/access: "true"`. The Service forwards port
  80 to that container port; the policy does not permit every caller merely
  because it knows the Service IP. Replies to accepted connections are allowed
  without an unrestricted outbound rule.
- Egress: UDP and TCP 53 only to Pods with `k8s-app=kube-dns` in the namespace
  labeled `kubernetes.io/metadata.name=kube-system`. Those namespace and Pod
  selectors are in the same peer and therefore both must match.

No general internet, AWS API, Kubernetes API, external telemetry, or arbitrary
Pod-to-Pod egress is added. The current in-memory API does not need those paths.
The optional HPA uses cluster resource metrics, not a new application metrics
port. Additional requirements need a reviewed policy change rather than opening
all egress.

Configure `networkPolicy.ingressPeers` to add specific controllers/clients. For
example, allowing a known ingress controller (verify its actual labels first):

```yaml
networkPolicy:
  ingressPeers:
    - podSelector:
        matchLabels:
          inventory-api/access: "true"
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
      podSelector:
        matchLabels:
          app.kubernetes.io/component: controller
```

A namespaceSelector plus podSelector in one peer is an AND. Label selectors
must be nonempty, so empty all-Pod/all-namespace selectors are rejected.
Reviewed IPv4 `ipBlock` sources /16 or narrower are supported for network paths
that preserve client addresses. An empty ingressPeers list denies ingress.
Ingress and HTTPRoute resources do not automatically approve their controllers;
set the appropriate peer when enabling either. These labels are authorization
criteria only within the trust granted to namespace/Pod writers, not cryptographic
client identity or application authentication.

For NodeLocal DNS or differently labeled CoreDNS, adjust the DNS selectors and/or
set `networkPolicy.dns.additionalServerCIDRs` to the exact resolver /32 addresses.
Those optional peers get only TCP/UDP 53. They are the only configurable extra
egress destinations in this baseline. Service DNAT, node-local resolvers, and
host-network traffic vary by CNI; confirm the observed packet path.

**NetworkPolicy requires an enforcing CNI.** Plain kindnet does not enforce it.
Use/configure a capable CNI such as Calico/Cilium or an appropriately enabled AWS
VPC CNI setup, then test allowed AND denied traffic. API acceptance of the policy
alone proves neither isolation nor DNS reachability. Existing policies are
additive: another permissive policy selecting these Pods can broaden access.
Kubelet/node traffic and host-network paths can also have implementation-specific
exceptions; this is not a complete host firewall or Layer 7 security policy.

### Service and denial verification

In the workload namespace, an approved test client must carry
`inventory-api/access=true`. From that client, a request to
`http://<release-service-name>/health` must return 200, and DNS lookup must work.
Use a client image already available in the cluster, or arrange image-pull access.

On an enforcing CNI, an otherwise identical client without the label must time
out when connecting to the application Service. From an application Pod, a
connection to a controlled non-DNS destination must be blocked; compare against
an unselected control Pod that can reach the same destination so an unrelated
routing failure is not mistaken for NetworkPolicy enforcement. Keep test client
and server resources temporary. Port-forward and node-originated probes are
not evidence that the Pod allowlist is enforced.

## RBAC

The chart creates no Role, RoleBinding, ClusterRole, or ClusterRoleBinding. It
needs no Kubernetes API access. A dedicated ServiceAccount with no grants and
no mounted token is sufficient; no cluster-admin binding is used. ConfigMap and
Secret environment injection is performed by Kubernetes, not by giving the
application API read permissions. If reusing an existing ServiceAccount, audit
all existing namespaced/cluster bindings; the chart cannot revoke grants created
by another operator. Default Kubernetes discovery permissions may still exist
for authenticated identities; that is not a workload-specific grant.

An administrator can audit an installed account with `kubectl auth can-i list
secrets --as=system:serviceaccount:<namespace>:<serviceaccount> -n <namespace>`;
expect `no` unless some external binding grants it. Keep node/AWS IAM permissions
separate from Kubernetes RBAC. Future Kubernetes API use requires a narrowly
scoped, separately reviewed design rather than turning on a broad default role.

## Verification performed

On 2026-10-22, the hardened chart was rendered and applied in a unique temporary
namespace on local `kind-devops-lab`, using inventory-api:1.0 and one replica.
The namespace was deleted after the checks. Existing workloads and AWS were not
modified. Observed:

- UID 10001, effective capabilities zero, NoNewPrivs=1, Seccomp=2.
- No `/var/run/secrets/kubernetes.io/serviceaccount/token`.
- Writing `/app/security-write-probe` raised errno 30 (read-only filesystem),
  rather than merely an ownership permission error.
- Creating/removing the /tmp marker produced readiness 200 → 503 → 200;
  liveness stayed 200, and asset creation/retrieval/deletion succeeded.
- An approved client reached the intended Service through cluster DNS with 200.
- NetworkPolicy was installed, but traffic-denial enforcement was **not verified**:
  the local cluster uses non-enforcing kindnet. Do not claim production network
  isolation from this test.

Render tests also assert security contexts, writable storage, policy rules,
absence of RBAC resources, and rejection of unsafe overrides. Run:

```sh
helm lint helm/inventory-api --strict
python3 -m unittest discover -s helm/inventory-api/tests -v
```

References: [Kubernetes security contexts](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
and [NetworkPolicy behavior and limitations](https://kubernetes.io/docs/concepts/services-networking/network-policies/).
