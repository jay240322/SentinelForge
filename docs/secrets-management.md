# SentinelForge - Kubernetes Secret Management Strategy

This document details the secret-management architecture, operational procedures, rotation workflows, and security guarantees for SentinelForge running on Kubernetes with Argo CD GitOps.

---

## 1. Architectural Strategy & Design Principles

SentinelForge employs **Kubernetes Native Secrets with Out-of-Band Operator Provisioning**.

```
+-------------------------------------------------------------+
|                      Git Repository                         |
|  - k8s/backend.yaml (valueFrom.secretKeyRef)                |
|  - k8s/postgres.yaml (valueFrom.secretKeyRef)               |
|  - k8s/secrets.example.yaml (Placeholders only)             |
|  - .gitignore (*.secret.yaml, *.env.secrets, *.key, *.sql)  |
+------------------------------+------------------------------+
                               | (Syncs declarative manifests)
                               v
+-------------------------------------------------------------+
|                     Argo CD Controller                      |
|  - Tracks resources via app.kubernetes.io/instance          |
|  - Unmanaged secrets in 'sentinelforge' are NOT pruned      |
+------------------------------+------------------------------+
                               | (Deploys Workloads)
                               v
+-------------------------------------------------------------+
|              Kubernetes Cluster (sentinelforge)             |
|                                                             |
|   [Operator Provisioned Secrets - NOT in Git]               |
|   * sentinelforge-postgres-secret                           |
|   * sentinelforge-database-secret                           |
|   * sentinelforge-backend-secret                            |
|                                  ^                          |
|         (Mounted into Pods via)  |                          |
|   [Workloads]                    |                          |
|   * Pod: backend  ---------------+                          |
|   * Pod: postgres ---------------+                          |
|   * PVC: postgres-pvc (Preserved across all secret ops)     |
+-------------------------------------------------------------+
```

### Why Native Secrets with Operator CLI?
1. **Zero Enterprise Complexity**: Eliminates reliance on external cloud KMS, HashiCorp Vault clusters, or complex proprietary CRDs for self-hosted deployments.
2. **True GitOps Separation**: Application manifests live in Git; real credentials **never** touch Git.
3. **Argo CD Compatibility**: Argo CD prune (`prune: true`) only deletes resources bearing its tracking annotations/labels (`app.kubernetes.io/instance`). Standalone Kubernetes Secrets created in the namespace are preserved and will not be deleted or modified during automated GitOps synchronizations.
4. **Reproducibility**: The `scripts/manage-secrets.sh` CLI automates generation, validation, application, and rotation in a single command.
5. **PVC & Database Safety**: Supports injecting existing credentials so existing database volumes (`postgres-pvc`) are never broken or wiped.

---

## 2. Required Secrets & Consumption Matrix

| Secret Name | Key | Type | Consumed By | Description & Security Requirements |
| :--- | :--- | :--- | :--- | :--- |
| `sentinelforge-postgres-secret` | `POSTGRES_PASSWORD` | String / Opaque | `Deployment: postgres` (env `POSTGRES_PASSWORD`) | Superuser password for PostgreSQL (`sentinelforge`). Minimum 16 characters. |
| `sentinelforge-database-secret` | `DATABASE_URL` | String / Opaque | `Deployment: backend` (env `DATABASE_URL`) | SQLAlchemy async connection string: `postgresql+asyncpg://sentinelforge:<PASSWORD>@postgres:5432/sentinelforge`. Must match `POSTGRES_PASSWORD`. |
| `sentinelforge-backend-secret` | `JWT_SECRET_KEY` | String / Opaque | `Deployment: backend` (env `JWT_SECRET_KEY`) | High-entropy 256-bit cryptographic secret for HMAC-SHA256 signing of access and refresh JWTs. Minimum 32 bytes (64 hex characters). |
| `sentinelforge-backend-secret` | `JWT_ALGORITHM` | String / Opaque | `Deployment: backend` (env `JWT_ALGORITHM`) | Cryptographic signing algorithm (Default: `HS256`). |
| `sentinelforge-backend-secret` | `ACCESS_TOKEN_EXPIRE_MINUTES` | String / Opaque | `Deployment: backend` (env `ACCESS_TOKEN_EXPIRE_MINUTES`) | Access token lifespan in minutes (Default: `15`). |
| `sentinelforge-backend-secret` | `REFRESH_TOKEN_EXPIRE_DAYS` | String / Opaque | `Deployment: backend` (env `REFRESH_TOKEN_EXPIRE_DAYS`) | Refresh token lifespan in days (Default: `7`). |

---

## 3. Operator Installation Workflows

### Scenario A: New Cluster Setup (Automated Random Generation)
For fresh installations without existing data:
```bash
# 1. Apply secrets with auto-generated high-entropy credentials
./scripts/manage-secrets.sh apply --generate-missing

# 2. Verify secrets exist in the cluster (without exposing values)
./scripts/manage-secrets.sh status

# 3. Apply Kubernetes application manifests or let Argo CD sync
kubectl apply -f k8s/
```

### Scenario B: Connecting to an Existing Database (Preserving PVC Data)
> [!IMPORTANT]
> PostgreSQL only reads `POSTGRES_PASSWORD` during cluster initialization (empty PVC). If connecting to an existing PVC, you **must** supply the existing database password so PostgreSQL and the backend match:

```bash
# 1. Copy the operator template
cp .env.secrets.example .env.secrets

# 2. Edit .env.secrets with your existing database password and desired JWT key
# (File is strictly ignored by .gitignore)
nano .env.secrets

# 3. Apply to Kubernetes
./scripts/manage-secrets.sh apply --from-env .env.secrets

# 4. Verify status
./scripts/manage-secrets.sh status
```

### Scenario C: Generating Declarative Manifests for Air-Gapped Review
To generate manifests for offline inspection outside Git:
```bash
./scripts/manage-secrets.sh apply --generate-missing --output-yaml /tmp/sentinelforge-secrets.yaml
# Review /tmp/sentinelforge-secrets.yaml (created with 0600 permissions)
kubectl apply -f /tmp/sentinelforge-secrets.yaml
rm /tmp/sentinelforge-secrets.yaml
```

---

## 4. Secret Rotation Procedures

### A. JWT Secret Key Rotation
Rotating the JWT key invalidates all active user sessions (refresh and access tokens):
```bash
# Rotate with auto-generated key and trigger rolling restart of backend:
./scripts/manage-secrets.sh rotate-jwt

# Or provide a specific key:
./scripts/manage-secrets.sh rotate-jwt --new-key "your-new-64-char-hex-secret-key"
```
**Mechanism**:
1. Patches `sentinelforge-backend-secret` with the new key.
2. Performs `kubectl rollout restart deployment backend -n sentinelforge`.
3. Monitors rollout status to ensure zero downtime.

### B. PostgreSQL Password Rotation (Live Database & PVC Preservation)
Rotating the database password requires synchronizing both PostgreSQL and the backend connection string:
```bash
# Safely rotate DB password across PostgreSQL, secrets, and backend:
./scripts/manage-secrets.sh rotate-db
```
**Mechanism**:
1. Connects to the active `postgres` pod and executes `ALTER USER sentinelforge WITH PASSWORD '<NEW_PASS>';`.
2. Patches `sentinelforge-postgres-secret` with the new password.
3. Updates `DATABASE_URL` in `sentinelforge-database-secret`.
4. Performs a rolling restart of the `backend` deployment.
5. Verifies backend connection health. Existing PVC data and tables remain 100% intact.

---

## 5. Security Invariants & What Must NEVER Be Committed

> [!CAUTION]
> **Strict Security Invariants**:
> 1. **NEVER commit real secrets**: `.env`, `.env.secrets`, `*.secret.yaml`, and `*.key` files must never be committed to Git.
> 2. **NEVER print secret values**: Scripts and CI logs must mask or suppress credential contents.
> 3. **NEVER put secrets into frontend code**: The Next.js frontend has zero secrets; authentication is handled via HTTP cookies and backend API endpoints.
> 4. **NEVER bake secrets into Docker images**: Dockerfiles must never contain credentials, and `.dockerignore` must exclude all `.env*` and `*.secret.yaml` files.
> 5. **NEVER delete existing PVCs during secret updates**: PVCs store persistent application data; secret updates must never touch PVC definitions.

---

## 6. Audit & Leak-Check Verification

Run the security audit script locally or in CI:
```bash
./scripts/check-secret-leaks.sh
```
This script validates:
- `.gitignore` patterns
- Git index and commit history for credential patterns
- Dockerfile and `.dockerignore` hygiene
- Kubernetes manifests for plaintext leaks
- Frontend code for backend secret leakage
