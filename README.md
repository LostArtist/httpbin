# httpbin — Production-Hardened Deployment

> Fork of [postmanlabs/httpbin](https://github.com/postmanlabs/httpbin) with a production-grade
> CI/CD pipeline, hardened container image, and Kubernetes manifests.
> The application itself is a Python/Flask HTTP testing service. This fork adds
> DevOps hardening: multi-stage Docker build, GitHub Actions CI/CD, and Kubernetes deployment.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Build & Run Locally with Docker](#2-build--run-locally-with-docker)
3. [Deploy to Local Kubernetes Cluster](#3-deploy-to-local-kubernetes-cluster)
4. [CI/CD Pipeline — Step-by-Step](#4-cicd-pipeline--step-by-step)
5. [Project Structure](#5-project-structure)
6. [Known Issues / Trade-offs](#6-known-issues--trade-offs)

---

## 1. Prerequisites

### For Docker (local build and run)

| Tool | Version | Install |
|------|---------|---------|
| Docker | 24+ | [docs.docker.com](https://docs.docker.com/get-docker/) |
| openssl | any | pre-installed on macOS/Linux |

### For Kubernetes (local cluster)

| Tool | Version | Install |
|------|---------|---------|
| Docker | 24+ | [docs.docker.com](https://docs.docker.com/get-docker/) |
| minikube | 1.32+ | [minikube.sigs.k8s.io](https://minikube.sigs.k8s.io/docs/start/) |
| kubectl | 1.29+ | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |

### For CI/CD (GitHub Actions)

- A public GitHub repository (fork of this project)
- Repository **Settings → Actions → General → Workflow permissions** set to **Read and write**

---

## 2. Build & Run Locally with Docker

### Step 1 — Clone the repository

```bash
git clone https://github.com/lostartist/httpbin.git
cd httpbin
```

### Step 2 — Build the image

```bash
docker build -t httpbin:local .
```

The build uses a multi-stage Dockerfile:
- **Stage 1 (builder):** installs all Python dependencies into `/opt/venv` using gcc and libffi-dev
- **Stage 2 (runtime):** copies only the venv and application source, upgrades OS packages to patch known CVEs, creates a non-root user, and sets a minimal attack surface

### Step 3 — Run the container

```bash
docker run --rm -d \
  --name httpbin-test \
  -p 8080:8080 \
  -e HTTPBIN_SECRET_KEY="$(openssl rand -hex 32)" \
  -e HTTPBIN_TRACKING_CODE="LOCAL-DEV" \
  --read-only \
  --tmpfs /tmp \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  httpbin:local
```

All security flags mirror the Kubernetes `securityContext`:
- `--read-only` — filesystem is read-only (equivalent to `readOnlyRootFilesystem: true`)
- `--tmpfs /tmp` — only `/tmp` is writable, mounted as in-memory tmpfs
- `--cap-drop ALL` — all Linux capabilities dropped
- `--security-opt no-new-privileges` — prevents privilege escalation

### Step 4 — Verify the application responds

```bash
sleep 4
curl -s http://localhost:8080/get | python3 -m json.tool
curl -s http://localhost:8080/headers | python3 -m json.tool
curl -s http://localhost:8080/ip | python3 -m json.tool
```

### Step 5 — Stop the container

```bash
docker stop httpbin-test
```


> **Important:** File depolyment.yaml is now configured for local testing. For DevOps testing change image to httpbin:latest 
>  and imagePullPolicy: Always. Precise instructions are located in the deployment.yaml.
---

## 3. Deploy to Local Kubernetes Cluster

### Step 1 — Start minikube

```bash
minikube start --cpus=2 --memory=4096 --addons=metrics-server
minikube status
```

The `metrics-server` addon is required for the HorizontalPodAutoscaler to function.
Expected output:
```
minikube
type: Control Plane
host: Running
kubelet: Running
apiserver: Running
kubeconfig: Configured
```

### Step 2 — Build the image into minikube's Docker daemon

Point your local Docker CLI at minikube's internal Docker daemon so the image is available to the cluster without pushing to a registry:

```bash
eval $(minikube docker-env)
docker build -t httpbin:local .
```

> **Important:** This command only affects the current shell session.
> Open a new terminal and you are back to your normal Docker daemon.

`imagePullPolicy: Never` tells Kubernetes to use only what is in the local daemon and never attempt a registry pull.

### Step 3 — Create the namespace

```bash
kubectl apply -f k8s/namespace.yaml
```

### Step 4 — Create the Secret

The `k8s/secret.yaml` file is an intentional placeholder — no plaintext value is ever committed to Git. Create the secret imperatively:

```bash
kubectl create secret generic httpbin-secret \
  --namespace=httpbin \
  --from-literal=HTTPBIN_SECRET_KEY="$(openssl rand -hex 32)"
```

Verify:
```bash
kubectl describe secret httpbin-secret -n httpbin
```

If you need to recreate it (idempotent):
```bash
kubectl create secret generic httpbin-secret \
  --namespace=httpbin \
  --from-literal=HTTPBIN_SECRET_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 5 — Apply all remaining manifests

```bash
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/hpa.yaml
kubectl apply -f k8s/networkpolicy.yaml
```

### Step 6 — Wait for pods to become ready

```bash
kubectl get pods -n httpbin
```

Check that both pods reach `1/1 Running` within ~60 seconds:
```
NAME                     READY   STATUS    RESTARTS   AGE
httpbin-xxxxxxxxx-xxxxx  1/1     Running   0          45s
httpbin-xxxxxxxxx-xxxxx  1/1     Running   0          45s
```

If pods are restarting, check events or re-apply networking policy
```bash
kubectl describe pod -n httpbin -l app.kubernetes.io/name=httpbin
kubectl logs -n httpbin -l app.kubernetes.io/name=httpbin --tail=30

# temporarily delete allow-httpbin-ingress
kubectl delete networkpolicy allow-httpbin-ingress -n httpbin

# check for pods to reach 1/1 READY and re-apply
kubectl apply -f k8s/networkpolicy.yaml
```

### Step 7 — Verify all Kubernetes resources

```bash
kubectl get all -n httpbin
kubectl get hpa -n httpbin
kubectl get networkpolicy -n httpbin
kubectl get configmap -n httpbin
kubectl get secret -n httpbin
```

### Step 8 — Access the application

```bash
kubectl port-forward svc/httpbin 8080:80 -n httpbin &
sleep 3

curl -s http://localhost:8080/get | python3 -m json.tool
curl -s http://localhost:8080/headers | python3 -m json.tool
curl -s http://localhost:8080/ip | python3 -m json.tool
```

### Teardown

```bash
kubectl delete namespace httpbin
minikube stop

# full reset:
minikube delete
```

## 4. CI/CD Pipeline — Step-by-Step

The pipeline is defined in `.github/workflows/ci.yml` and triggers on every push to `main` and on pull requests. All quality gate jobs run in parallel before the image is built. The pipeline will only deploy if every preceding job passes.

```
lint ────────────────────────────────────────────────────┐
test ──────┐                                             │
sast ──────┼── (all must pass) ──► build-and-push ──► trivy-scan ──► deploy
dep-audit ─┘
secret-scan ┘
```

### Job 1 — Lint (`ruff`)

Runs `ruff check` and `ruff format` over all Python source files. Ruff enforces PEP 8 compliance, import ordering (standard → third-party → local), unused imports, f-string usage, and removal of unnecessary unicode/UTF-8 literals.

### Job 2 — Unit Tests (`pytest`)

Executes the existing `test_httpbin.py` test suite (67 tests) against Python 3.12 with all production dependencies installed. Tests cover all HTTP methods, redirect chains, digest auth, streaming, compression (gzip, brotli), CORS headers, and range requests. The job fails if any test fails or errors.

### Job 3 — SAST (`bandit`)

Performs AST-level static analysis of all Python source files. Bandit detects: hardcoded passwords, use of `assert` in production code, `subprocess` with `shell=True`, weak cryptographic functions (`md5`, `sha1`), SQL injection patterns, and other CWE-mapped security issues. The scan runs at medium severity and above (`-ll`).

### Job 4 — Dependency Audit (`pip-audit`)

Queries the OSV (Open Source Vulnerabilities) database and PyPI advisory feed against every package in `requirements.txt`. The job fails with `--strict` if any dependency has a known CVE with a published fix available. This catches vulnerable transitive dependencies before they reach the image.

### Job 5 — Secret Detection (`gitleaks`)

Scans the **entire commit history** (`fetch-depth: 0`) for accidentally committed secrets, API keys, tokens, private keys, and high-entropy strings. This covers all historical commits, not just the current HEAD, making it effective against secrets committed and later deleted.

### Job 6 — Build & Push (`docker/build-push-action` → `ghcr.io`)

Runs only after all five quality gates pass. Builds the multi-stage image using Docker Buildx with GitHub Actions layer cache, then pushes to GitHub Container Registry (`ghcr.io/lostartist/httpbin`) tagged with the short commit SHA and `latest`. SBOM and provenance attestations are generated automatically. The image name is forced to lowercase to satisfy OCI registry requirements.

### Job 7 — Image Scan (`trivy`)

Pulls the freshly pushed image from GHCR and scans all OS packages and Python library layers for CVEs. The pipeline **fails** on any finding with severity `HIGH` or `CRITICAL`.

### Job 8 — Deploy / Validate K8s Manifests

Spins up a real `kind` cluster inside the GitHub Actions runner, creates the namespace and a placeholder secret, applies all manifests from `k8s/`, and verifies the Deployment, Service, and HPA objects were created successfully. This validates manifest syntax and Kubernetes API compatibility without requiring access to a production cluster.

---


## 5. Known Issues / Trade-offs

### Python 3.12 Compatibility

The httpbin source code was written against Python 2.7 era dependencies. Running it on Python 3.12 required patching three categories of issues: `werkzeug.wrappers.BaseResponse` was removed in Werkzeug 2.1 (replaced with `Response`), `werkzeug.http.parse_authorization_header` was removed in Werkzeug 3.x (replaced with `Authorization.from_header()`), and `WWWAuthenticate.set_digest()` was removed in Werkzeug 2.1 (replaced with direct dict-style attribute assignment). All three patches are a minimal amount of line changes in `core.py` and `helpers.py`.

### Werkzeug / Flask Version Pinning

The dependency stack is pinned to Flask 3.1.3, Werkzeug 3.1.6, and Jinja2 3.1.6 — the latest patched versions for now. These are the minimum versions that resolve all CVEs reported by pip-audit while remaining compatible with the application source.

### Secret Management

The local development workflow creates secrets imperatively via `kubectl create secret` so that no plaintext value ever enters Git history. For a production pipeline, the correct approach is `Bitnami Sealed Secrets` or the `External Secrets Operator` integrated with HashiCorp Vault, AWS Secrets Manager, or Azure Key Vault. These are documented in the CI pipeline's deploy job as the intended production path. Such a key also lies in k8s/secret.yaml as an example.

### OS-Level CVEs in Base Image

The `python:3.12-slim` base image is Debian-based and periodically contains OS-level CVEs. The Dockerfile includes `apt-get upgrade` in the runtime stage to pull patched package versions directly from Debian's apt repositories.

### NetworkPolicy and Kubernetes Health Probes

Kubernetes liveness, readiness, and startup probes are executed by the **kubelet** running on the host network (not by a pod). A default-deny-all ingress NetworkPolicy without an explicit source selector will block probe traffic because the kubelet is not a pod and does not match any `podSelector` or `namespaceSelector`. The `allow-httpbin-ingress` policy permits traffic from any source on port 8080 (no `from:` block) to ensure probes reach the container. In production, the `from:` block should be restricted to the ingress controller's namespace.

### HPA and metrics-server

The HorizontalPodAutoscaler requires `metrics-server` to be running in the cluster. On minikube this is an optional addon that must be explicitly enabled: `minikube addons enable metrics-server`. If `kubectl get hpa -n httpbin` shows `TARGETS: <unknown>/70%`, wait 60 seconds for the first metrics scrape cycle to complete.

### Distroless vs. python:3.12-slim

The task suggests `distroless` as an option, however it lacks a shell, package manager, and writable home directory, which conflicts with gunicorn's worker heartbeat file handling and flasgger's Swagger UI template initialization. `python:3.12-slim` with explicit hardening (non-root user, `readOnlyRootFilesystem`, dropped capabilities, `apt-get upgrade`) achieves equivalent attack surface reduction while maintaining WSGI compatibility.

### Production Improvements Not in Scope

TLS termination via an Ingress resource with cert-manager, Prometheus/Grafana ServiceMonitor for gunicorn metrics, image tag pinned to immutable SHA digest instead of latest (recommended), External Secrets Operator integration.

> **Important:** The documentation was formulated and styled with use of AI in order to avoid grammar mistakes and make it loud and clear. Except for documentation, all the work was done by hand.
