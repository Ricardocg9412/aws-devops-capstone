# Infrastructure Inventory API

FastAPI REST API with a process-local, in-memory infrastructure inventory. Requires Python 3.11+.

## Run locally

```sh
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
uvicorn app.main:app --host "${UVICORN_HOST:-127.0.0.1}" --port "${UVICORN_PORT:-8000}" --workers 1 --no-access-log
```

Open Swagger UI at http://127.0.0.1:8000/docs, ReDoc at `/redoc`, or the OpenAPI schema at `/openapi.json`.

## Run with Docker

From the repository root, with Docker running:

```sh
docker build -f docker/Dockerfile -t inventory-api:1.0 .
docker run -d --name inventory-api -p 127.0.0.1:8080:8080 inventory-api:1.0
curl -i http://127.0.0.1:8080/health
docker logs -f inventory-api
```

Open http://127.0.0.1:8080/docs for Swagger UI. The image runs as a non-root user with one worker and uses `/health` for its Docker health check. Inside the container, `UVICORN_HOST` defaults to `0.0.0.0` and `UVICORN_PORT` to `8080`; the host port is bound to loopback by the run command. Supply application configuration with `docker run -e INVENTORY_LOG_LEVEL=DEBUG ...` before the image name.

The Dockerfile uses two stages. `builder` installs production dependencies into `/opt/venv`. `runtime` copies that virtual environment and the application code into a fresh Python image. Both stages use the same Python base to keep the copied environment compatible. Dependency installation is cached until `requirements.txt` changes; application-only edits reuse it. Build commands remain the same. This separates dependency installation from runtime assembly; it does not guarantee a smaller image for this pure-Python application, which already used a slim base and disabled pip caching.

Simulate readiness failure inside the running container:

```sh
docker exec inventory-api touch /tmp/inventory-api.unready
curl -i http://127.0.0.1:8080/ready   # 503
curl -i http://127.0.0.1:8080/health  # 200
docker exec inventory-api rm /tmp/inventory-api.unready
curl -i http://127.0.0.1:8080/ready   # 200
```

Stop and remove the container:

```sh
docker stop inventory-api
docker rm inventory-api
```

Inventory state is lost whenever the application restarts, including `docker restart`. A readiness marker remains in a restarted container's writable filesystem until removed; recreating the container removes it.

If changing the Dockerfile or application, rebuild the image and recreate the container. Restarting an existing container does not apply a rebuilt image. Port publishing uses `HOST_PORT:CONTAINER_PORT`; Uvicorn must listen on the container port. Check `docker logs inventory-api` to confirm it listens on `0.0.0.0:8080`.

## Deploy to Kubernetes

Prerequisites: a running Kubernetes cluster, `kubectl` configured for that cluster, and the `inventory-api:1.0` image available to every node that can schedule a Pod. Run commands from the repository root.

### Make the image available

Build the image using the Docker command above. For a local cluster, load it using the command appropriate to your setup:

```sh
# kind: replace <cluster-name> with your cluster's name
kind load docker-image inventory-api:1.0 --name <cluster-name>

# Alternatively, for the active minikube profile
minikube image load inventory-api:1.0
```

For a remote cluster, tag and push the image to an accessible container registry, and change `spec.template.spec.containers[0].image` in `k8s/deployment.yaml` to that registry reference before applying. Private registries also require image pull credentials. Building locally alone does not make the image available to remote nodes.

### Apply the Deployment and Service

```sh
kubectl create namespace devops-lab --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl rollout status deployment/inventory-api -n devops-lab
kubectl get pods,services -n devops-lab
```

The manifests define:

| Resource | Current configuration |
| --- | --- |
| Deployment | `inventory-api`, namespace `devops-lab`, 2 replicas |
| Container | `inventory-api:1.0`, port 8080 |
| Resource requests per container | 250m CPU, 512Mi memory |
| Resource limits per container | 1000m CPU, 1Gi memory |
| Readiness probe | `/ready` on 8080, every 5s, 2s timeout, 3 failures to become unready |
| Liveness probe | `/health` on 8080, every 10s, 2s timeout, 3 failures before restart |
| Service | `inventory-api-service`, default ClusterIP, TCP port 80 → container port 8080 |
| Service selector | `app: inventory-api`, matching the Deployment's Pod labels |

The image supplies `UVICORN_HOST=0.0.0.0` and `UVICORN_PORT=8080`; the Deployment does not override them. Its `containerPort` declaration does not configure Uvicorn's listening port. Kubernetes uses the manifest probes, independently of the Dockerfile health check.

**Each replica has a separate inventory.** The current two-replica configuration demonstrates multiple Pods but cannot provide a shared, consistent inventory. For consistent CRUD testing, use one replica:

```sh
kubectl scale deployment/inventory-api --replicas=1 -n devops-lab
```

This changes the live Deployment; reapplying the current manifest restores two replicas. Change `spec.replicas` in the manifest to `1` if you want that setting to persist across applies.

### Access the Service

Run this in a dedicated terminal:

```sh
kubectl port-forward service/inventory-api-service 8000:80 -n devops-lab
```

Then use http://127.0.0.1:8000/docs or:

```sh
curl -i http://127.0.0.1:8000/health
curl -i http://127.0.0.1:8000/ready
```

Here port 8000 is the local port, 80 is the Service port, and 8080 is the container's listening port. Service port-forwarding selects one backing Pod; it does not demonstrate balancing requests across all replicas.

### Inspect and simulate readiness failure

```sh
kubectl logs deployment/inventory-api -n devops-lab --tail=20
kubectl describe deployment inventory-api -n devops-lab
kubectl get pods -n devops-lab -l app=inventory-api

# Select a specific Pod for the simulation
inventory_pod=$(kubectl get pods -n devops-lab -l app=inventory-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n devops-lab "$inventory_pod" -- touch /tmp/inventory-api.unready
kubectl get pods -n devops-lab -l app=inventory-api -w
```

After the readiness probe reaches its failure threshold, the selected Pod becomes unready while its liveness endpoint remains healthy. Stop watching with Ctrl+C, then restore readiness:

```sh
kubectl exec -n devops-lab "$inventory_pod" -- rm /tmp/inventory-api.unready
kubectl get pods -n devops-lab -l app=inventory-api -w
```

Service traffic can continue through another ready replica. To observe the failing Pod directly, forward its port in a separate terminal with `kubectl port-forward -n devops-lab pod/<pod-name> 8081:8080`, then request `http://127.0.0.1:8081/ready` (503) and `/health` (200). A direct port-forward can still reach an unready Pod.

### Remove the deployment

```sh
kubectl delete -f k8s/service.yaml -f k8s/deployment.yaml
```

This leaves the namespace intact. Container restarts, Pod replacement, and rolling updates lose the affected process's inventory.

## Reusable Helm chart

[`helm/inventory-api`](helm/inventory-api/README.md) packages the application as a
Deployment, Service, dedicated ServiceAccount with token automount disabled, and
ConfigMap. Defaults match the lab requirements: image `inventory-api:1.0`, two
replicas, container port 8080, Service port 80, health/readiness probes, and
100m/128Mi requests with 500m/256Mi limits. These are lab resource settings.
Separate dev/prod values, optional HPA, existing Secret references, and rolling
updates are documented in the chart README. Multiple replicas still have
independent in-memory inventories.

```sh
helm lint helm/inventory-api --strict
helm template inventory-api-dev helm/inventory-api --namespace devops-lab \
  -f helm/inventory-api/values-dev.yaml
python3 -m unittest discover -s helm/inventory-api/tests -v
```

Chart creation and tests do not install anything into Kubernetes. See the chart
README for installation and migration guidance; existing `k8s/` manifests remain
available and are managed independently.

## Endpoints

| Method | Path | Behavior |
| --- | --- | --- |
| GET | `/health` | 200 while the process can serve requests |
| GET | `/ready` | 200 after startup and while the readiness marker is absent; otherwise 503 |
| GET | `/items` | 200 with a JSON array of assets (initially empty) |
| GET | `/items/{id}` | 200 with the asset, or 404 |
| POST | `/items` | 201 with the created asset and Location header; duplicate ID: 409 |
| DELETE | `/items/{id}` | 204 with an empty body; absent ID: 404 |

Example:

```sh
curl -i http://127.0.0.1:8000/items \
  -H 'Content-Type: application/json' \
  -d '{"id":"srv-001","name":"application-server","environment":"dev","type":"ec2","status":"running"}'
curl http://127.0.0.1:8000/items/srv-001
curl http://127.0.0.1:8000/items
curl -i -X DELETE http://127.0.0.1:8000/items/srv-001
```

All five fields are required strings. Environments are exactly `dev`, `qa`, or `prod`. IDs are case-sensitive, start with an ASCII letter or digit, and contain only letters, digits, dots, underscores, and hyphens (128 characters maximum). Other strings are trimmed and must be nonempty; name allows 256 characters, type/status 128. Type and status remain open strings. Extra fields, missing fields, malformed JSON, and invalid values return 422. Duplicate creation preserves the existing asset.

## Configuration

Configuration is read from environment variables at application creation. Invalid configuration fails startup. No `.env` file is loaded automatically.

| Variable | Default | Purpose |
| --- | --- | --- |
| `INVENTORY_LOG_LEVEL` | `INFO` | Request logging level: DEBUG, INFO, WARNING, ERROR, CRITICAL |
| `INVENTORY_UNREADY_FILE` | `/tmp/inventory-api.unready` | Absolute or working-directory-relative path to readiness failure marker |
| `UVICORN_HOST` | Local: `127.0.0.1`; image: `0.0.0.0` | Uvicorn bind address |
| `UVICORN_PORT` | Local: `8000`; image: `8080` | Uvicorn listening port |

Requests produce JSON logs on stdout with UTC timestamp, level, message, HTTP method, path, status code, client address, and elapsed milliseconds. Bodies and query strings are not logged. The run command disables Uvicorn's separate access log to avoid duplicate request entries.

## Liveness and readiness simulation

Liveness checks whether the process can respond. Readiness requires completed startup and a healthy simulated dependency, represented by the absence of a marker file. A filesystem error during the check also fails readiness. Startup completes even when the marker already exists, allowing the process to remain alive while unready.

With the server running and the default configuration:

```sh
touch /tmp/inventory-api.unready
curl -i http://127.0.0.1:8000/ready   # 503
curl -i http://127.0.0.1:8000/health  # 200
rm /tmp/inventory-api.unready
curl -i http://127.0.0.1:8000/ready   # 200
```

Use the configured path if overriding `INVENTORY_UNREADY_FILE`. No restart is necessary. Inventory endpoints remain callable while unready; readiness signals a load balancer or orchestrator to stop routing traffic. There is no unauthenticated administrative toggle endpoint.

## Storage and consistency

**All state is lost on process restart.** There is no database, persistence, or fixed item-count limit; capacity is bounded by available memory and supports more than ten assets. A lock makes duplicate checking and insertion atomic and protects reads/deletes across concurrent requests. Use one worker and one replica when a consistent inventory is required: multiple processes each have independent inventories. The Kubernetes manifest currently runs two replicas; see the scaling instructions above. Reloading the development server also loses state.

## Tests

Tests run locally through FastAPI's in-process `TestClient`. No running server, Docker, Kubernetes, or AWS is required.

```sh
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
python -m pytest -v
```

Run a single test:

```sh
python -m pytest tests/test_api.py::test_duplicate_does_not_overwrite -v
```

The current suite covers asset creation, retrieval, listing and deletion; duplicate rejection and preservation; concurrent duplicate creation; missing assets; invalid fields and malformed JSON; parametrized valid environments; twenty-item capacity; readiness failure, recovery and startup; state loss; configuration; structured request logging; and Swagger/OpenAPI availability. Invalid payload cases are parametrized, including `staging` as an invalid environment.

Function-scoped fixtures create a fresh application and sample payload for each test. Readiness markers use pytest's `tmp_path`, and `TestClient` runs startup and shutdown through a context manager. Tests create their own required data rather than relying on another test's execution.

### Statement coverage and execution order

Coverage and randomized-order tooling are optional and are not currently included in `requirements-dev.txt`. Install them before using these commands:

```sh
python -m pip install pytest-cov pytest-randomly
python -m pytest --cov=app --cov-report=term-missing --cov-fail-under=80 --randomly-seed=42
python -m pytest --randomly-seed=7
python -m pytest --randomly-seed=123
```

The coverage command measures application statement coverage and exits unsuccessfully if it is below 80% or a test fails. Different seeds exercise different test orders and help detect shared-state dependencies. These commands provide a way to validate the threshold and order independence; no measured coverage percentage is asserted here.

## Terraform AWS networking

The root at [`terraform/environments/dev`](terraform/environments/dev/README.md)
uses the reusable [`network` module](terraform/modules/network/README.md) to
create the VPC, two public and two private subnets, routing, and baseline
security groups. The default `10.20.0.0/16` topology matches the assignment.
NAT is optional and disabled by default; no EKS cluster or VPC endpoints are
created. The module README documents the production NAT/endpoint decision.

```sh
terraform -chdir=terraform/environments/dev init -backend=false
terraform -chdir=terraform/environments/dev validate
terraform -chdir=terraform/environments/dev test
terraform -chdir=terraform/modules/network init -backend=false
terraform -chdir=terraform/modules/network validate
terraform -chdir=terraform/modules/network test
```

Tests use mocked AWS providers and do not provision AWS resources. See the root
README for actual planning commands, inputs, outputs, and credentials requirements.

## Terraform ECR and publishing identities

The dev root also uses the [`ecr` module](terraform/modules/ecr/README.md) for a
KMS-encrypted ECR repository with immutable tags, scan-on-push, and lifecycle
cleanup, plus separate GitHub publisher, EKS cluster, and EKS node roles. GitHub
OIDC trust matches one repository and branch or protected environment exactly.
See the [root configuration](terraform/environments/dev/README.md#ecr-and-iamoidc)
for defaults, existing OIDC provider reuse, and immutable GitHub subject IDs to
verify before deployment. No long-lived publishing credentials are required.

## EKS definitions — not deployed

The [`eks` module](terraform/modules/eks/README.md) defines a private Kubernetes
1.35 cluster, explicit access entries, complete control-plane logging, and
AL2023 managed workers (desired 2, min 1, max 3) in private subnets. Public-IP
subnet settings are blocked by a tested precondition. The dev root defaults to
`enable_eks=false`; no cluster or node group has been deployed. See the module
README for private administrative access, network prerequisites, AMI strategy,
and default/custom KMS encryption behavior.

## Mocked Terraform acceptance tests

See [Terraform testing](terraform/TESTING.md) for the six required configuration
conditions, two explicit invalid-input cases, mock computed-attribute strategy,
and commands to run the suites or just the requirement-specific tests. These
checks use mocked AWS providers and do not deploy infrastructure.

## Architecture decisions

- [ADR 0001: Terraform state management](docs/adr/0001-terraform-state-management.md) — proposed AWS backend operation, locking, encryption, environment isolation, recovery, and secret handling. Documentation only; no backend deployed.

Run every local Terraform check (formatting, backend-disabled initialization,
validation, and mocked root/module tests) with:

```sh
./scripts/terraform-validate.sh
```

The script stops at the first failure with a nonzero exit code. Provider downloads
may require internet access, but tests do not contact AWS. See
[Terraform testing](terraform/TESTING.md#one-command-validation) for how this differs
from a real AWS plan.

## Application runtime security

The Helm chart now enforces UID 10001, non-root execution, no privileges or
escalation, dropped capabilities, RuntimeDefault seccomp, a read-only root
filesystem, no host namespaces, and no mounted ServiceAccount token. A bounded
writable `/tmp` emptyDir preserves readiness simulation. Its NetworkPolicy allows
approved application clients and DNS only; no Kubernetes RBAC grants are created.
See [runtime security](helm/inventory-api/SECURITY.md) for configuration,
verification, and the CNI enforcement limitation. This baseline applies to the
Helm deployment; migrate from the earlier standalone lab manifests accordingly.

## Kyverno application admission policies

[`kyverno/`](kyverno/README.md) contains six namespaced policies for non-root
execution, CPU/memory limits, no privileged containers, read-only root filesystems,
explicit non-latest image tags, and approved image repositories. They use the
installed Kyverno 1.19.2 namespaced CEL API and target only `devops-lab`.
The allowlist accounts for kind's `docker.io/library/inventory-api` image name.
See the README for offline fixtures, server-side dry-run, and deliberate
activation. The policy definitions have not been installed by this change.

### Continuous integration

`.github/workflows/ci.yaml` runs the four source-validation jobs and the container checks below on pull requests to
`main`, pushes to `main`, and manual dispatch. Each uses an explicit
`ubuntu-24.04` runner. There are no path filters, so Python changes always run
application checks alongside infrastructure and policy checks.

- `python-tests`: Python 3.11, dependencies from `requirements-dev.txt`, pytest,
  and statement coverage with an 80% minimum. JUnit XML, coverage XML, and HTML
  coverage are uploaded as `python-test-reports` for 14 days, including when
  tests fail if reports were generated.
- `terraform-validate`: Terraform 1.16.6 runs `./scripts/terraform-validate.sh`.
  Initialization skips remote backends, uses committed provider lock files,
  and tests use mocked AWS providers. Provider installation needs internet
  access, but these checks require no AWS credentials and run no real AWS plan.
- `helm-validate`: Helm 4.3.1 lints and renders default, dev, and prod values,
  then runs the Python chart suite, including security, HPA, and invalid values.
- `kyverno-test`: official Kyverno CLI 1.19.2 container runs the local namespaced
  CEL tests with a read-only repository mount; no cluster is required.

Actions are pinned to full commit SHAs with release comments. The token has
only `contents: read`, checkout does not persist credentials, and there are no
cloud credentials, deployment secrets, publishing steps, or
`pull_request_target` triggers. Any future publishing/deployment workflow must
separately restrict execution to trusted branches/events and approved environments.
PR code runs only on disposable GitHub-hosted runners.

Python jobs cache pip downloads using both requirements files as cache inputs;
dependency changes invalidate the key, and installation still runs on every job.
The version ranges in requirements are not a full dependency lock, so unchanged
ranges may resolve to newer compatible releases. Terraform provider selections
remain controlled by committed lock files.

### Container build, advisory vulnerability scan, and image handoff

CI also runs three separate jobs:

1. `docker-build` builds the existing `docker/Dockerfile` with repository-root
   context, tagging the single-platform Linux/amd64 image as
   `inventory-api:${{ github.sha }}`. Buildx uses GitHub Actions layer caching
   (`cache-from` / `cache-to`, `mode=max`). Dockerfile and dependency changes
   invalidate the affected layers. GitHub cache branch scoping isolates PR
   writes from the trusted main-branch cache.
2. `image-scan` downloads and verifies the image archive, then scans that exact
   archive with Trivy 0.76.1. Scanning is **advisory**: HIGH and CRITICAL OS
   and application-library vulnerabilities are reported, including those without
   available fixes, but findings do not fail CI (`exit-code: '0'`). Scanner and
   database errors still fail the job; there is no `continue-on-error`.
   The JSON vulnerability report is retained for 14 days when generated,
   including on scan failure. This advisory mode does not satisfy the original
   assignment's requirement for a failing severity-based security gate.
3. `integration-test` requires the scan to complete successfully, even if it
   reports vulnerabilities. It downloads the same artifact
   from the current workflow run, verifies its SHA-256 checksum, loads it, and
   compares its Docker image ID with the recorded build identity. It runs
   `scripts/image-integration-test.sh` without rebuilding or pulling the image.
   Checks cover startup, health, OpenAPI, readiness failure and recovery while
   running as UID 10001 with a read-only root filesystem and writable `/tmp`.
   The container runs only on the disposable CI runner and is always cleaned up.

The `inventory-image-<commit SHA>` artifact contains the Docker archive, archive
checksum, and image ID, retained for three days. This follows Docker's
[image handoff between jobs](https://docs.docker.com/build/ci/github-actions/share-image-jobs/)
pattern. The workflow SHA on a PR normally identifies GitHub's tested merge
commit, rather than only the contributor's head commit.

Build success, scan completion, publication, and deployment are
separate outcomes. Uploading an internal workflow artifact is only a test
handoff. This workflow never logs into ECR or Docker Hub, pushes an image, or
performs an external deployment. Passing build, scan, and integration checks is
not release approval; any future publishing/deployment stage must separately
require trusted events/branches, all required checks, and environment approval.
To smoke-test an already-loaded image locally:

```sh
./scripts/image-integration-test.sh inventory-api:1.0
```
