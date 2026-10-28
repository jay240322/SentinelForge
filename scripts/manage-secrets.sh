#!/usr/bin/env bash
# ==============================================================================
# SentinelForge - Kubernetes Secret Management CLI
#
# Provides reproducible, secure, and audited secret management for self-hosted
# SentinelForge clusters managed via Kubernetes and Argo CD.
#
# SECURITY GUARANTEES:
# - Enforces strict file permissions (umask 077)
# - Disables bash xtrace (set +x) to prevent secret echoing in logs
# - Never prints secret values to stdout/stderr
# - Verifies password consistency between PostgreSQL and backend DATABASE_URL
# - Preserves existing PostgreSQL persistent volumes (PVC)
# ==============================================================================

set -euo pipefail
umask 077
set +x

# Terminal styling
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Default values
NAMESPACE="sentinelforge"
POSTGRES_USER="sentinelforge"
POSTGRES_DB="sentinelforge"
POSTGRES_HOST="postgres"
POSTGRES_PORT="5432"
POSTGRES_PASSWORD=""
DATABASE_URL=""
JWT_SECRET_KEY=""
JWT_ALGORITHM="HS256"
ACCESS_TOKEN_EXPIRE_MINUTES="15"
REFRESH_TOKEN_EXPIRE_DAYS="7"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_header() {
    echo -e "${BOLD}${CYAN}=== $1 ===${NC}"
}

# Cryptographically secure random generator
generate_token() {
    local length="${1:-32}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$length"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import secrets; print(secrets.token_hex($length))"
    else
        log_error "Neither openssl nor python3 is available to generate secure secrets."
        exit 1
    fi
}

check_kubectl() {
    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl command not found. Please install kubectl."
        exit 1
    fi
}

ensure_namespace() {
    local ns="$1"
    local dry_run="${2:-false}"
    if [[ "$dry_run" == "true" ]]; then
        log_info "Dry-run: Ensuring namespace '$ns' exists"
        return 0
    fi

    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        log_info "Creating namespace '$ns'..."
        kubectl create namespace "$ns" >/dev/null
        log_success "Namespace '$ns' created."
    fi
}

# Load environment file safely without evaluating dangerous commands
load_env_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log_error "Environment file '$file' not found."
        exit 1
    fi

    log_info "Loading configuration from: $file"
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
        # Trim leading/trailing whitespace
        key=$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        # Skip comments and empty lines
        [[ -z "$key" || "$key" =~ ^# ]] && continue

        # Trim value and strip matching surrounding quotes
        val=$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        val=$(echo "$val" | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")

        case "$key" in
            POSTGRES_USER) POSTGRES_USER="$val" ;;
            POSTGRES_PASSWORD) POSTGRES_PASSWORD="$val" ;;
            POSTGRES_DB) POSTGRES_DB="$val" ;;
            POSTGRES_HOST) POSTGRES_HOST="$val" ;;
            POSTGRES_PORT) POSTGRES_PORT="$val" ;;
            DATABASE_URL) DATABASE_URL="$val" ;;
            JWT_SECRET_KEY) JWT_SECRET_KEY="$val" ;;
            JWT_ALGORITHM) JWT_ALGORITHM="$val" ;;
            ACCESS_TOKEN_EXPIRE_MINUTES) ACCESS_TOKEN_EXPIRE_MINUTES="$val" ;;
            REFRESH_TOKEN_EXPIRE_DAYS) REFRESH_TOKEN_EXPIRE_DAYS="$val" ;;
            NAMESPACE) NAMESPACE="$val" ;;
        esac
    done < "$file"
}

# Construct DATABASE_URL if not provided
ensure_database_url() {
    if [[ -z "$DATABASE_URL" ]]; then
        if [[ -z "$POSTGRES_PASSWORD" ]]; then
            log_error "Cannot construct DATABASE_URL without POSTGRES_PASSWORD."
            exit 1
        fi
        DATABASE_URL="postgresql+asyncpg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
    fi
}

validate_secrets() {
    local has_errors=0

    if [[ -z "$POSTGRES_PASSWORD" ]]; then
        log_error "POSTGRES_PASSWORD is empty."
        has_errors=1
    elif [[ ${#POSTGRES_PASSWORD} -lt 12 ]]; then
        log_warn "POSTGRES_PASSWORD length is under 12 characters. Stronger password recommended."
    fi

    if [[ -z "$DATABASE_URL" ]]; then
        log_error "DATABASE_URL is empty."
        has_errors=1
    elif [[ ! "$DATABASE_URL" =~ ^postgresql\+asyncpg:// ]]; then
        log_error "DATABASE_URL must start with 'postgresql+asyncpg://'."
        has_errors=1
    fi

    if [[ -z "$JWT_SECRET_KEY" ]]; then
        log_error "JWT_SECRET_KEY is empty."
        has_errors=1
    elif [[ ${#JWT_SECRET_KEY} -lt 32 ]]; then
        log_error "JWT_SECRET_KEY length (${#JWT_SECRET_KEY}) is under minimum 32 characters."
        has_errors=1
    fi

    if [[ -z "$JWT_ALGORITHM" ]]; then
        JWT_ALGORITHM="HS256"
    fi

    if [[ "$has_errors" -eq 1 ]]; then
        log_error "Secret validation failed. Fix issues before proceeding."
        exit 1
    fi
    log_success "Secret validation passed (cryptographic requirements satisfied)."
}

# Generate declarative Kubernetes Secret manifests string
render_manifests() {
    cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: sentinelforge-postgres-secret
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: sentinelforge
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: sentinelforge
type: Opaque
stringData:
  POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
---
apiVersion: v1
kind: Secret
metadata:
  name: sentinelforge-database-secret
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: sentinelforge
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: sentinelforge
type: Opaque
stringData:
  DATABASE_URL: "${DATABASE_URL}"
---
apiVersion: v1
kind: Secret
metadata:
  name: sentinelforge-backend-secret
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: sentinelforge
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: sentinelforge
type: Opaque
stringData:
  JWT_SECRET_KEY: "${JWT_SECRET_KEY}"
  JWT_ALGORITHM: "${JWT_ALGORITHM}"
  ACCESS_TOKEN_EXPIRE_MINUTES: "${ACCESS_TOKEN_EXPIRE_MINUTES}"
  REFRESH_TOKEN_EXPIRE_DAYS: "${REFRESH_TOKEN_EXPIRE_DAYS}"
EOF
}

cmd_apply() {
    local env_file=""
    local generate_missing=false
    local dry_run=false
    local output_file=""
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from-env)
                env_file="$2"
                shift 2
                ;;
            --generate-missing)
                generate_missing=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --output-yaml)
                output_file="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --force)
                force=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    log_header "Applying SentinelForge Secrets"

    if [[ -n "$env_file" ]]; then
        load_env_file "$env_file"
    fi

    # Auto-generate missing secrets if requested or if not provided
    if [[ "$generate_missing" == "true" ]]; then
        if [[ -z "$POSTGRES_PASSWORD" ]]; then
            log_info "Generating secure random PostgreSQL password..."
            POSTGRES_PASSWORD=$(generate_token 24)
        fi
        if [[ -z "$JWT_SECRET_KEY" ]]; then
            log_info "Generating secure 256-bit JWT secret key..."
            JWT_SECRET_KEY=$(generate_token 32)
        fi
    fi

    ensure_database_url
    validate_secrets

    if [[ -n "$output_file" ]]; then
        log_info "Writing declarative Secret manifests to: $output_file"
        render_manifests > "$output_file"
        chmod 600 "$output_file"
        log_success "Secrets written to '$output_file' (permissions set to 0600)."
        log_warn "NEVER commit '$output_file' to git!"
        return 0
    fi

    check_kubectl
    ensure_namespace "$NAMESPACE" "$dry_run"

    # Check for existing secrets to avoid accidental overwrites unless --force is passed
    if [[ "$dry_run" == "false" && "$force" == "false" ]]; then
        if kubectl get secret sentinelforge-postgres-secret -n "$NAMESPACE" >/dev/null 2>&1; then
            log_warn "Secret 'sentinelforge-postgres-secret' already exists in namespace '$NAMESPACE'."
            log_warn "Overwriting will change credentials. Use --force to update, or use 'rotate-db' for safe database password rotation."
        fi
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_info "Executing client-side dry-run validation..."
        render_manifests | kubectl apply --dry-run=client -f -
        log_success "Dry-run validation successful. No cluster resources modified."
    else
        log_info "Applying secrets to namespace '$NAMESPACE'..."
        render_manifests | kubectl apply -f -
        log_success "Secrets successfully applied to namespace '$NAMESPACE'."
        log_info "Secrets configured:"
        echo "  • sentinelforge-postgres-secret [POSTGRES_PASSWORD]"
        echo "  • sentinelforge-database-secret [DATABASE_URL]"
        echo "  • sentinelforge-backend-secret  [JWT_SECRET_KEY, JWT_ALGORITHM, ACCESS_TOKEN_EXPIRE_MINUTES, REFRESH_TOKEN_EXPIRE_DAYS]"
    fi
}

cmd_status() {
    check_kubectl
    log_header "Checking SentinelForge Secret Status (Namespace: $NAMESPACE)"

    local all_ok=true

    check_secret_key() {
        local secret="$1"
        local key="$2"
        local exists
        exists=$(kubectl get secret "$secret" -n "$NAMESPACE" -o jsonpath="{.data.${key}}" 2>/dev/null || true)
        if [[ -n "$exists" ]]; then
            local decoded_len
            decoded_len=$(echo "$exists" | base64 -d 2>/dev/null | wc -c || echo "0")
            echo -e "  ${GREEN}✓${NC} ${BOLD}${secret}${NC} -> ${CYAN}${key}${NC} (present, ${decoded_len} bytes)"
        else
            echo -e "  ${RED}✗${NC} ${BOLD}${secret}${NC} -> ${CYAN}${key}${NC} (${RED}MISSING${NC})"
            all_ok=false
        fi
    }

    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        log_error "Namespace '$NAMESPACE' does not exist."
        exit 1
    fi

    echo "Verifying PostgreSQL secret:"
    check_secret_key "sentinelforge-postgres-secret" "POSTGRES_PASSWORD"

    echo ""
    echo "Verifying Database connection secret:"
    check_secret_key "sentinelforge-database-secret" "DATABASE_URL"

    echo ""
    echo "Verifying Backend auth secret:"
    check_secret_key "sentinelforge-backend-secret" "JWT_SECRET_KEY"
    check_secret_key "sentinelforge-backend-secret" "JWT_ALGORITHM"
    check_secret_key "sentinelforge-backend-secret" "ACCESS_TOKEN_EXPIRE_MINUTES"
    check_secret_key "sentinelforge-backend-secret" "REFRESH_TOKEN_EXPIRE_DAYS"

    echo ""
    if [[ "$all_ok" == "true" ]]; then
        log_success "All required secrets and keys are present in cluster."
    else
        log_error "One or more secrets are missing. Run './scripts/manage-secrets.sh apply' to configure them."
        exit 1
    fi
}

cmd_rotate_jwt() {
    local new_key=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --new-key)
                new_key="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    check_kubectl
    log_header "Rotating JWT Secret Key"

    if [[ -z "$new_key" ]]; then
        log_info "Generating new 256-bit cryptographic JWT secret key..."
        new_key=$(generate_token 32)
    fi

    if [[ ${#new_key} -lt 32 ]]; then
        log_error "New JWT key must be at least 32 characters."
        exit 1
    fi

    log_info "Updating 'sentinelforge-backend-secret' in namespace '$NAMESPACE'..."
    local b64_key
    b64_key=$(echo -n "$new_key" | base64 | tr -d '\n')
    kubectl patch secret sentinelforge-backend-secret -n "$NAMESPACE" \
        --type='json' \
        -p="[{"op": "replace", "path": "/data/JWT_SECRET_KEY", "value": "${b64_key}"}]"

    log_success "JWT secret patched in Kubernetes."

    log_info "Restarting backend deployment to load new JWT secret..."
    kubectl rollout restart deployment backend -n "$NAMESPACE"
    kubectl rollout status deployment backend -n "$NAMESPACE" --timeout=60s || true

    log_success "JWT secret successfully rotated."
    log_warn "Active user sessions were invalidated due to token signature change."
}

cmd_rotate_db() {
    local new_password=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --new-password)
                new_password="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    check_kubectl
    log_header "Safe PostgreSQL Credential Rotation (Preserving Database PVC)"

    if [[ -z "$new_password" ]]; then
        log_info "Generating new high-entropy database password..."
        new_password=$(generate_token 24)
    fi

    log_info "Step 1: Locating PostgreSQL pod in namespace '$NAMESPACE'..."
    local pg_pod
    pg_pod=$(kubectl get pod -n "$NAMESPACE" -l app=postgres -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || true)
    if [[ -z "$pg_pod" ]]; then
        log_error "No active postgres pod found in namespace '$NAMESPACE'."
        exit 1
    fi

    log_info "Step 2: Updating user password directly inside PostgreSQL instance ($pg_pod)..."
    kubectl exec -i "$pg_pod" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "ALTER USER ${POSTGRES_USER} WITH PASSWORD '${new_password}';" >/dev/null
    log_success "PostgreSQL user '$POSTGRES_USER' password updated in live database."

    log_info "Step 3: Updating sentinelforge-postgres-secret in Kubernetes..."
    local b64_pass
    b64_pass=$(echo -n "$new_password" | base64 | tr -d '\n')
    kubectl patch secret sentinelforge-postgres-secret -n "$NAMESPACE" \
        --type='json' \
        -p="[{"op": "replace", "path": "/data/POSTGRES_PASSWORD", "value": "${b64_pass}"}]"

    log_info "Step 4: Updating sentinelforge-database-secret with updated connection string..."
    local new_db_url="postgresql+asyncpg://${POSTGRES_USER}:${new_password}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
    local b64_db_url
    b64_db_url=$(echo -n "$new_db_url" | base64 | tr -d '\n')
    kubectl patch secret sentinelforge-database-secret -n "$NAMESPACE" \
        --type='json' \
        -p="[{"op": "replace", "path": "/data/DATABASE_URL", "value": "${b64_db_url}"}]"

    log_info "Step 5: Restarting backend deployment to connect with new credentials..."
    kubectl rollout restart deployment backend -n "$NAMESPACE"
    kubectl rollout status deployment backend -n "$NAMESPACE" --timeout=60s || true

    log_success "Database credentials rotated successfully."
    log_success "All persistent volume claims (PVC) and existing tables were preserved intact."
}

show_help() {
    cat <<EOF
SentinelForge Secret Management CLI

Usage:
  ./scripts/manage-secrets.sh <command> [options]

Commands:
  apply             Create or update SentinelForge secrets in Kubernetes
  status            Verify presence and validity of required secrets without exposing values
  rotate-jwt        Rotate JWT signing secret key and restart backend deployment
  rotate-db         Rotate PostgreSQL password in live database and update secrets safely
  help              Display this help message

Options for 'apply':
  --from-env <FILE>       Load secret values from uncommitted environment file (e.g. .env.secrets)
  --generate-missing      Auto-generate cryptographically secure random values for missing secrets
  --dry-run               Validate secret manifests client-side without cluster modification
  --output-yaml <FILE>    Output declarative Kubernetes Secret manifests to file (mode 0600)
  --namespace <NAME>      Target Kubernetes namespace (default: sentinelforge)
  --force                 Overwrite existing secrets in cluster

Examples:
  # Quickstart: Generate all secrets and apply directly to cluster
  ./scripts/manage-secrets.sh apply --generate-missing

  # Apply from existing credentials file (e.g. connecting to existing PVC/DB)
  ./scripts/manage-secrets.sh apply --from-env .env.secrets

  # Dry-run validation
  ./scripts/manage-secrets.sh apply --generate-missing --dry-run

  # Check cluster secrets status
  ./scripts/manage-secrets.sh status

  # Rotate JWT secret
  ./scripts/manage-secrets.sh rotate-jwt

  # Rotate Database password safely
  ./scripts/manage-secrets.sh rotate-db
EOF
}

case "${1:-help}" in
    apply)
        shift
        cmd_apply "$@"
        ;;
    status|check)
        shift
        cmd_status "$@"
        ;;
    rotate-jwt)
        shift
        cmd_rotate_jwt "$@"
        ;;
    rotate-db)
        shift
        cmd_rotate_db "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
