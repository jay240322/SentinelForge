# SentinelForge - Local Kubernetes Access Guide

This guide describes how to reliably access SentinelForge in local development on Windows with WSL2, Minikube (Docker driver), and NGINX Ingress.

---

## Architecture & Routing Overview

SentinelForge uses Kubernetes NGINX Ingress to provide unified routing for both the Next.js frontend and FastAPI backend:

- **Ingress Host**: `http://sentinelforge.local:8090`
- **Frontend Routing**: `/` $\rightarrow$ `service/frontend:3000`
- **Backend API Routing**: `/api` $\rightarrow$ `service/backend:8000`
- **Database & Cache**: PostgreSQL (with persistent volume claim) and Redis remain internal to the cluster (ClusterIP) for security and isolation.

---

## Local Setup Requirements

### 1. Prerequisites
- Windows 10/11 with WSL2 enabled (Ubuntu)
- Minikube with `docker` driver
- NGINX Ingress addon enabled (`minikube addons enable ingress`)
- `kubectl` configured to interact with Minikube

### 2. Configure Hostname Resolution (`sentinelforge.local`)

Because Minikube running under the Docker driver on WSL2 isolates container bridge IPs (e.g., `192.168.49.2`) from direct Windows network routing, Windows and WSL resolve `sentinelforge.local` to `127.0.0.1` (localhost), pairing with Ingress controller port-forwarding on port 8090.

#### Windows Setup
Add the following line to `C:\Windows\System32\drivers\etc\hosts` (open Notepad as Administrator):
```hosts
127.0.0.1 sentinelforge.local
```

#### WSL Setup
Add the following line to `/etc/hosts`:
```hosts
127.0.0.1 sentinelforge.local
```

---

## Running & Accessing SentinelForge Locally

### 1. Start Minikube & Deploy Resources
```bash
# Start Minikube with the docker driver
minikube start --driver=docker

# Apply Kubernetes manifests
kubectl apply -f k8s/
```

### 2. Expose the Ingress Controller
Port-forward the Ingress controller service port 80 to local port 8090:
```bash
kubectl port-forward -n ingress-nginx service/ingress-nginx-controller 8090:80
```

### 3. Open in Browser
Navigate to:
- **Application Web UI**: [http://sentinelforge.local:8090](http://sentinelforge.local:8090)
- **API Endpoints**: `http://sentinelforge.local:8090/api/v1/auth/login`

---

## Health & Verification

1. **Verify Pod & Service Status**:
   ```bash
   kubectl get pods,svc,ingress,pvc -n sentinelforge
   ```
2. **Verify Frontend**:
   ```bash
   curl -I -H "Host: sentinelforge.local" http://127.0.0.1:8090/
   ```
3. **Verify API & Authentication via Ingress**:
   ```bash
   curl -X POST http://sentinelforge.local:8090/api/v1/auth/login \
     -H "Content-Type: application/json" \
     -d '{"email":"testuser@sentinelforge.com","password":"StrongPassword123!"}'
   ```

---

## Argo CD GitOps Operations Guide

SentinelForge uses declarative GitOps deployment managed by Argo CD.

### 1. Application Architecture & Configuration
The GitOps application is defined in `argocd/application.yaml`:
- **Repository**: `https://github.com/jay240322/sentinelforge.git`
- **Target Branch / Revision**: `develop`
- **Path**: `k8s/`
- **Destination**: `https://kubernetes.default.svc` in namespace `sentinelforge`
- **Sync Policy**: Automated sync with Self-Healing (`selfHeal: true`) and Pruning (`prune: true`).

### 2. Inspecting the Application
- **View Application Overview**:
  ```bash
  kubectl get application sentinelforge -n argocd
  ```
- **View Detailed Status & Managed Resources**:
  ```bash
  kubectl get application sentinelforge -n argocd -o yaml
  ```
- **View Managed Resources in Namespace**:
  ```bash
  kubectl get all,pvc,ingress -n sentinelforge
  ```

### 3. Manual Sync & Reconciliation
If automated sync is paused or you need an immediate refresh:
- **Trigger Argo CD Reconciliation**:
  ```bash
  kubectl patch application sentinelforge -n argocd --type merge -p '{"operation":{"sync":{"prune":true}}}'
  ```
- **Hard Refresh from Git**:
  ```bash
  kubectl patch application sentinelforge -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
  ```

### 4. Health & Status Checks
- **Check Health & Sync Status**:
  ```bash
  kubectl get application sentinelforge -n argocd
  ```
- **Check Live Pods & Workloads**:
  ```bash
  kubectl get pods,svc,pvc,ingress -n sentinelforge
  ```

### 5. Troubleshooting Sync Failures
- **View Application Error / Sync Conditions**:
  ```bash
  kubectl get application sentinelforge -n argocd -o jsonpath='{.status.conditions}'
  ```
- **Inspect Application Controller Logs**:
  ```bash
  kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=100
  ```
- **Inspect Repo Server Logs**:
  ```bash
  kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100
  ```
- **Common Failure Scenarios & Resolutions**:
  1. *Git Connectivity / Revision Error*: Ensure the Git repository URL is correct and branch exists in remote.
  2. *Schema Validation Errors*: Validate manifests locally with `kubectl apply --dry-run=client -f k8s/` before pushing.
  3. *Resource Immutability (e.g. PVC size reduction)*: PersistentVolumeClaims cannot be reduced in size.
  4. *Missing Secrets*: External secrets must exist in namespace `sentinelforge` prior to pod scheduling.
