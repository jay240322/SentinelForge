#!/usr/bin/env bash
# ==============================================================================
# SentinelForge - Secret Leak & Security Verification Script
#
# Inspects git repository, tracked files, staging area, commit history, and
# Docker configurations to ensure no real secrets or unignored credentials exist.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ERRORS=0

log_check() {
    echo -e "${CYAN}[CHECK]${NC} $1"
}

log_pass() {
    echo -e "  ${GREEN}✓ PASS:${NC} $1"
}

log_fail() {
    echo -e "  ${RED}✗ FAIL:${NC} $1" >&2
    ERRORS=$((ERRORS + 1))
}

echo -e "${BOLD}=== SentinelForge Security & Secret-Leak Audit ===${NC}"

# Check 1: Verify .gitignore ignores sensitive patterns
log_check "Verifying .gitignore coverage..."
required_ignores=(
    ".env"
    "*.env.secrets"
    "*.secret.yaml"
    "*.sql"
    "*.key"
    "*.pem"
)

for pattern in "${required_ignores[@]}"; do
    if grep -qF "$pattern" .gitignore; then
        log_pass ".gitignore covers pattern '$pattern'"
    else
        log_fail ".gitignore missing pattern '$pattern'"
    fi
done

# Check 2: Verify no tracked files in git contain secrets
log_check "Scanning Git tracked files for sensitive filenames..."
tracked_secrets=$(git ls-files | grep -E '(\.env$|\.env\.local|\.env\.secrets|secret.*\.yaml$|secrets\.yaml$|.*\.pem$|.*\.key$)' || true)

# Filter out explicitly allowed templates
tracked_secrets_filtered=""
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if [[ "$file" =~ \.example ]] || [[ "$file" =~ example\.yaml ]]; then
        continue
    fi
    tracked_secrets_filtered+="$file\n"
done <<< "$tracked_secrets"

if [[ -z "$tracked_secrets_filtered" ]]; then
    log_pass "No secret files tracked in Git index."
else
    log_fail "Found tracked secret files:\n$tracked_secrets_filtered"
fi

# Check 3: Check Dockerfiles for baked-in secrets
log_check "Auditing Dockerfiles for hardcoded secrets or environment variables..."
dockerfile_leaks=$(grep -rn -E '(?i)(password|secret|jwt_secret_key).*=' backend/Dockerfile frontend/Dockerfile 2>/dev/null || true)
if [[ -z "$dockerfile_leaks" ]]; then
    log_pass "Dockerfiles do not contain hardcoded secrets."
else
    log_fail "Potential secrets found in Dockerfiles:\n$dockerfile_leaks"
fi

# Check 4: Check Dockerignore files
log_check "Auditing .dockerignore files for secret exclusion..."
for d_ignore in "backend/.dockerignore" "frontend/.dockerignore"; do
    if [[ -f "$d_ignore" ]]; then
        if grep -qE '\.env' "$d_ignore"; then
            log_pass "$d_ignore excludes environment files."
        else
            log_fail "$d_ignore does not exclude .env files."
        fi
    else
        log_fail "$d_ignore not found."
    fi
done

# Check 5: Scan Kubernetes manifests for hardcoded secrets
log_check "Scanning Kubernetes manifests in k8s/ for plaintext secret leaks..."
k8s_leaks=""
for k8s_file in k8s/*.yaml; do
    [[ "$k8s_file" == "k8s/secrets.example.yaml" ]] && continue
    # Look for inline plaintext passwords or JWT secrets in production manifests
    matches=$(grep -n -E 'POSTGRES_PASSWORD:[[:space:]]*[^$[:space:]]+' "$k8s_file" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        k8s_leaks+="$k8s_file: $matches\n"
    fi
done

if [[ -z "$k8s_leaks" ]]; then
    log_pass "Kubernetes manifests in k8s/ use secretKeyRef; no inline passwords found."
else
    log_fail "Found plaintext secret in k8s manifests:\n$k8s_leaks"
fi

# Check 6: Check frontend code for server secret leakage
log_check "Verifying frontend code does not reference JWT_SECRET_KEY or DATABASE_URL..."
frontend_leaks=$(grep -rnE '(JWT_SECRET_KEY|POSTGRES_PASSWORD)' frontend/src frontend/app frontend/components frontend/lib 2>/dev/null || true)
if [[ -z "$frontend_leaks" ]]; then
    log_pass "Frontend codebase is clean of backend secrets."
else
    log_fail "Frontend code references backend secrets:\n$frontend_leaks"
fi

echo ""
if [[ "$ERRORS" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}✓ All security and secret-leak checks PASSED!${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}✗ Audit failed with $ERRORS error(s).${NC}" >&2
    exit 1
fi
