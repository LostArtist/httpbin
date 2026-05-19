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