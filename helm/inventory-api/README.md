# Inventory API Helm chart

Reusable chart for the existing FastAPI container. The chart defines a
Deployment, Service, dedicated ServiceAccount, non-sensitive ConfigMap, and
baseline NetworkPolicy.
It does not install a cluster, ingress/Gateway controller, Metrics Server, or
Secret. Rendering and tests require no Kubernetes connection.

## Lab defaults

| Configuration | Default |
| --- | --- |
| Image | `inventory-api:1.0` |
| Pull policy | `IfNotPresent` |
| Fixed replicas | `2` |
| Container port | `8080` |
| Service | `ClusterIP`, port `80`, named target port `http` |
| Readiness / liveness | `/ready` / `/health` on the named container port |
| CPU request / limit | `100m` / `500m` |
| Memory request / limit | `128Mi` / `256Mi` |
| ServiceAccount | Dedicated, generated release-aware name; token automount disabled |
| Rollout | RollingUpdate, maxUnavailable 0, maxSurge 1, minReadySeconds 5 |

These are lab defaults, **not production sizing recommendations**. The application
stores inventory independently in each process. Two replicas, HPA scaling, Pod
replacement, and rolling updates do not share or preserve inventory. Use one
replica for consistent lab CRUD exploration; persistent shared storage is needed
before this becomes a consistent multi-replica inventory service.

## Inspect locally

Requires Helm 3 or 4. Run from the repository root:

```sh
helm lint helm/inventory-api --strict
helm lint helm/inventory-api -f helm/inventory-api/values-dev.yaml --strict
helm lint helm/inventory-api -f helm/inventory-api/values-prod.yaml --strict
helm template inventory-api-dev helm/inventory-api \
  --namespace devops-lab -f helm/inventory-api/values-dev.yaml
```

To install later into a selected cluster (not performed as part of chart creation):

```sh
helm upgrade --install inventory-api-dev helm/inventory-api \
  --namespace devops-lab --create-namespace \
  -f helm/inventory-api/values-dev.yaml --wait --timeout 5m
kubectl -n devops-lab port-forward service/inventory-api-dev 8000:80
```

Open http://127.0.0.1:8000/docs or request `/health` and `/ready`. For a local
cluster, ensure `inventory-api:1.0` is loaded into its nodes. For ECR, override
`image.repository` with the repository URL and use a published immutable version
in `image.tag`; nodes must have image-pull permissions and network connectivity.
For other private registries, `imagePullSecrets` accepts existing Secret names.

The chart uses the Helm release namespace, never a hardcoded namespace. A second
release uses different names/selectors, so it can coexist with the first.
`nameOverride` and `fullnameOverride` are supported; avoid naming collisions and
do not change selector identity (`nameOverride` or release name) for an existing
Deployment. Helm cannot automatically take ownership of existing resources from
`k8s/`. Use a distinct release name, verify the new Service, switch consumers,
and retire the old manifest-managed resources deliberately. The original
manifests have not been changed or deleted.

## Dev and prod profiles

- `values-dev.yaml`: one fixed replica, DEBUG logging, `environment=dev` label.
- `values-prod.yaml`: two fixed replicas, INFO logging, `environment=prod` label.

Both overlay `values.yaml`. The prod file is an environment example, not a
production-ready scaling/storage/security profile. It still inherits lab
resources and the local image; replace the image, measure resource needs, and
address application persistence before real production use. The label does not
create an application environment feature that the current FastAPI app lacks.

For example, a future production installation would use a separate release and
namespace and override image settings:

```sh
helm template inventory-api-prod helm/inventory-api \
  --namespace inventory-prod -f helm/inventory-api/values-prod.yaml \
  --set image.repository=registry.example.com/team/inventory-api \
  --set-string image.tag=sha-example
```

## Configuration reference

| Value | Purpose |
| --- | --- |
| `image.repository`, `image.tag`, `image.pullPolicy` | Container image selection; quote tags as strings |
| `replicaCount` | Fixed replica count when autoscaling is off |
| `containerPort` | Container listener; also supplies explicit `UVICORN_PORT` environment variable |
| `service.type`, `service.port` | Service exposure and client port; target remains named `http` |
| `commonLabels` | Extra labels on chart resources and Pods |
| `commonAnnotations` | Extra annotations on resource metadata |
| `podLabels`, `podAnnotations` | Extra Pod metadata |
| `deploymentAnnotations`, `service.annotations` | Per-resource metadata overrides |
| `resources.requests`, `resources.limits` | Kubernetes resource quantities; API enforces requests <= limits |
| `readinessProbe`, `livenessProbe`, `startupProbe` | HTTP paths, timing, headers; startup probe optional |
| `config` | String-valued, non-sensitive environment variables supplied by the ConfigMap |
| `existingSecret` | Name of an independently managed Secret, loaded through envFrom |
| `serviceAccount.create/name/automount/annotations` | Dedicated account by default; optional existing account; automount must remain false |
| `imagePullSecrets` | List such as `[{name: registry-credentials}]` |
| `strategy.rollingUpdate.maxSurge` | Positive integer surge allowance; unavailable replicas remain fixed at zero |
| `minReadySeconds`, `terminationGracePeriodSeconds` | Readiness stability and graceful termination windows |
| `autoscaling.*` | Optional CPU-utilization HPA |
| `ingress.*`, `httpRoute.*` | Optional ingress or Gateway HTTPRoute; both disabled by default |

Selector labels `app.kubernetes.io/name` and `app.kubernetes.io/instance` are
reserved and cannot be overridden. Extra labels are kept out of selectors so
ordinary label changes do not invalidate a Deployment's immutable selector.
Standard resource identity labels are chart-managed. Pod `checksum/config` is
also chart-managed and takes precedence over a supplied annotation value.

The ConfigMap defaults to `INVENTORY_LOG_LEVEL=INFO` and
`INVENTORY_UNREADY_FILE=/tmp/inventory-api.unready`. ConfigMap content changes
update the Pod checksum annotation and trigger a rolling update, because
environment variables do not refresh in an existing process. Container bind
address is explicitly `0.0.0.0`; `UVICORN_HOST` and `UVICORN_PORT` are reserved
from `config` to prevent port mismatches. Changing `containerPort` automatically
updates the listener environment, and Service/probes follow its named port.

Do not put passwords, tokens, or private keys in `values.yaml`, profile files,
`config`, CLI overrides, annotations, or labels. Helm stores supplied values in
its release metadata, and ConfigMaps are not secret storage. Provision secrets
independently (for example via an external secret manager/controller) and pass
only `existingSecret`. No Secret resource or secret value is rendered. Keep
Secret keys distinct from ConfigMap keys: later Secret envFrom entries override
ConfigMap duplicates, while explicit chart-managed bind/port, temporary-directory, bytecode, and
readiness-marker variables win.
External Secret changes need a separate controlled Pod restart/reloader; the
ConfigMap checksum does not track external Secret content.

With `serviceAccount.create=false`, `serviceAccount.name` is mandatory. Pod-level
`automountServiceAccountToken=false` remains effective even if an existing
account permits token mounts. No RBAC privileges are created. Token automount cannot be enabled through values for this chart: this API
does not need Kubernetes API access. A future API integration requires a
separate reviewed RBAC/token design.

## HPA, probes, and rollout compatibility

HPA is off by default. To enable it, use an override like:

```yaml
replicaCount: null
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70
```

The chart omits Deployment replicas when HPA is enabled. A fixed non-null replica
count combined with HPA is rejected, as are minReplicas > maxReplicas and missing
or zero CPU requests. The broader runtime baseline requires positive CPU and
memory requests/limits even when HPA is off. The application container requests
`100m` CPU by default. The 70% target is relative to requested CPU, not the CPU
limit: with this request, the target is an average of `70m` CPU per Pod.

Save the override above as `hpa-values.yaml`, then enable it with:

```sh
helm upgrade --install inventory-api ./helm/inventory-api \
  --namespace devops-lab --create-namespace -f hpa-values.yaml
```

Install a cluster-compatible [Metrics Server](https://github.com/kubernetes-sigs/metrics-server)
separately; this chart does not install it. Metrics Server collects CPU and memory
usage from node kubelets and exposes it through `metrics.k8s.io`. The HPA
controller reads that API to calculate CPU utilization and adjust the Deployment.
The application does not need a metrics endpoint, Kubernetes API permissions,
or additional application egress for CPU autoscaling. Verify metrics availability
and HPA status with:

```sh
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top pods -n devops-lab
kubectl get hpa -n devops-lab
kubectl describe hpa inventory-api -n devops-lab
```

The APIService should be available and `kubectl top` should return usage. Missing
metrics can show as `<unknown>` targets or `FailedGetResourceMetric` events;
check Metrics Server logs and its connectivity/TLS configuration to kubelets.
Local kind clusters may require additional Metrics Server configuration; follow
its installation requirements rather than disabling TLS verification in production.
See the [Kubernetes HPA documentation](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/).

Do not enable autoscaling just to hide in-memory inventory consistency issues. When migrating an existing fixed-replica release to HPA, review the
transition: removing the managed replicas field can cause a temporary scale
change before the HPA reconciles. Disabling HPA requires a fixed replica count.

HTTP probes use `port: http`; keep that name and provide paths the selected
image serves. Readiness and liveness are required; an optional startup probe
can delay their activation for slow startup. Schema validation catches invalid
ports, image tags/types, missing required fields, unknown value keys, and unsafe
rollout settings. The chart also rejects simultaneous ingress and HTTPRoute,
reserved selector labels, and attempts to override bind/port through `config`.
Ingress requires hosts/paths and a compatible controller; HTTPRoute requires
Gateway API CRDs, a controller, and parentRefs. These resources alone do not
configure TLS, DNS, or external infrastructure.

`maxUnavailable=0` keeps healthy old replicas available during a planned rollout;
`maxSurge=1` needs room for one additional Pod. An unschedulable/unready replacement
will stall the rollout instead of intentionally removing a healthy old replica.
This does not guarantee zero downtime during node failures, manual deletions,
network issues, or single-replica state loss, and it does not provide a PDB.

## Render tests

Requires Python, Helm, and PyYAML (`python3 -m pip install -r requirements-dev.txt`
in the project's virtual environment). No Helm test plugin or cluster is needed:

```sh
python3 -m unittest discover -s helm/inventory-api/tests -v
```

Tests check defaults, ports/selectors, release isolation, metadata, configuration
checksums, dev/prod profiles, HPA ownership, existing account/Secret references,
optional routing backends, and rejected configurations. They parse rendered YAML
with duplicate-key detection. Rendering does not validate live admission policy,
image availability, controllers, resource capacity, or actual HTTP probe responses.

References: [Helm named helpers](https://helm.sh/docs/chart_template_guide/named_templates/)
and [Kubernetes rolling updates](https://kubernetes.io/docs/tasks/run-application/update-deployment-rolling/).

## Runtime security baseline

See [SECURITY.md](SECURITY.md) for the enforced UID 10001/non-root baseline,
read-only root filesystem, dedicated writable `/tmp`, NetworkPolicy allowlists,
RBAC posture, and commands demonstrating rejected root-filesystem writes while
readiness and Service access continue working. Defaults also disable all host
namespaces, privileges, escalation, capability additions, and token automount.
Unsafe value overrides are rejected for every profile; the prod profile does
not weaken the baseline. Configure approved clients before expecting traffic
through the Service: default ingress requires the same-namespace Pod label
`inventory-api/access: "true"`. Optional ingress/Gateway controllers need their
own explicit approved peer. Policy enforcement requires a capable CNI.
