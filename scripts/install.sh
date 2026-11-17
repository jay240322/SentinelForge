#!/usr/bin/env bash
# ==============================================================================
# SentinelForge - Self-Hosted Installer (Docker Compose)
#
# Installs SentinelForge into a user-owned directory, generates cryptographic
# secrets, pulls pinned Docker images, runs database migrations and verifies
# the stack end-to-end.
#
# DESIGN RULES (security-sensitive code):
#   * Never prints secret values.
#   * Never uses eval or sources untrusted files.
#   * Never overwrites an existing .env or regenerates secrets for an
#     existing installation.
#   * Never publishes PostgreSQL or Redis ports.
#   * Is idempotent: re-running reuses existing configuration and data.
#
# Usage:
#   ./scripts/install.sh [options]
#
# Run with --help for the full option list.
# ==============================================================================

set -Eeuo pipefail
umask 077
set +x

readonly INSTALLER_VERSION="1.0.0"
readonly DEFAULT_PROJECT="sentinelforge"
readonly DEFAULT_PORT="8080"
readonly DEFAULT_BIND="127.0.0.1"
readonly DEFAULT_TAG="latest"
readonly DEFAULT_REPO="jay240322/sentinelforge"
readonly DEFAULT_REF="main"
readonly DEFAULT_GATEWAY_IMAGE="nginxinc/nginx-unprivileged:1.27-alpine"
readonly BACKEND_IMAGE_REPO="joypatel2403/sentinelforge-backend"
readonly FRONTEND_IMAGE_REPO="joypatel2403/sentinelforge-frontend"
readonly MIN_DISK_MB=5120
readonly RECOMMENDED_DISK_MB=10240
readonly DEFAULT_HEALTH_TIMEOUT=240
readonly DEFAULT_VERIFY_TIMEOUT=60
readonly COMPOSE_VERSION_MIN_MAJOR=2

# ------------------------------------------------------------------------------
# Global state
# ------------------------------------------------------------------------------
INSTALL_DIR="${SENTINELFORGE_HOME:-${HOME:-/tmp}/.sentinelforge}"
PROJECT="${SENTINELFORGE_PROJECT:-$DEFAULT_PROJECT}"
PORT="${SENTINELFORGE_PORT:-$DEFAULT_PORT}"
BIND_ADDRESS="${SENTINELFORGE_BIND:-$DEFAULT_BIND}"
IMAGE_TAG="${SENTINELFORGE_TAG:-$DEFAULT_TAG}"
REPO_SLUG="${SENTINELFORGE_REPO:-$DEFAULT_REPO}"
REPO_REF="${SENTINELFORGE_REF:-$DEFAULT_REF}"
ASSETS_DIR_OVERRIDE="${SENTINELFORGE_ASSETS_DIR:-}"
HEALTH_TIMEOUT="${SENTINELFORGE_HEALTH_TIMEOUT:-$DEFAULT_HEALTH_TIMEOUT}"
VERIFY_TIMEOUT="${SENTINELFORGE_VERIFY_TIMEOUT:-$DEFAULT_VERIFY_TIMEOUT}"

SKIP_PULL=false
SKIP_MIGRATIONS=false

PROJECT_SET=false
PORT_SET=false
BIND_SET=false
TAG_SET=false

OS_FAMILY=""
IS_WSL=false
ENV_FILE=""
TMP_WORK=""
LOCK_DIR=""
LOCK_ACQUIRED=false
ASSETS_SRC=""

# Colors only when attached to a terminal.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    BOLD=""
    NC=""
fi

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log_info() {
    printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"
}

log_success() {
    printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2
}

log_error() {
    printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*" >&2
}

log_step() {
    printf '\n%s%s==> %s%s\n' "$BOLD" "$CYAN" "$*" "$NC"
}

die() {
    log_error "$*"
    exit 1
}

die_usage() {
    log_error "$*"
    printf 'Run "%s --help" for usage.\n' "${0##*/}" >&2
    exit 2
}

on_err() {
    local line="${1:-unknown}"
    log_error "Installer aborted unexpectedly (line ${line})."
    log_error "No secret values were printed. See docs/installation.md#troubleshooting."
    exit 1
}

cleanup() {
    if [[ -n "${TMP_WORK:-}" && -d "$TMP_WORK" ]]; then
        rm -rf "$TMP_WORK"
    fi
    if [[ -n "${LOCK_DIR:-}" && -d "$LOCK_DIR" && "$LOCK_ACQUIRED" == "true" ]]; then
        rm -rf "$LOCK_DIR"
    fi
}

trap cleanup EXIT
trap 'on_err "$LINENO"' ERR

usage() {
    cat <<'EOF'
SentinelForge self-hosted installer (Docker Compose)

Usage:
  ./scripts/install.sh [options]

Options:
  --dir PATH              Installation directory (default: ~/.sentinelforge)
  --port PORT             Public HTTP port for the gateway (default: 8080)
  --bind ADDRESS          Host bind address (default: 127.0.0.1)
  --project-name NAME     Docker Compose project name (default: sentinelforge)
  --tag TAG               Image tag for backend/frontend (default: latest)
  --ref REF               Git ref used to fetch deployment assets when the
                          installer is piped via curl (default: main)
  --assets-dir PATH       Use deployment assets from a local directory
  --skip-pull             Do not pull images (offline or locally built images)
  --skip-migrations       Advanced: do not run Alembic migrations
  -h, --help              Show this help
  --version               Show installer version

Environment variables (all optional):
  SENTINELFORGE_HOME, SENTINELFORGE_PORT, SENTINELFORGE_BIND,
  SENTINELFORGE_PROJECT, SENTINELFORGE_TAG, SENTINELFORGE_REPO,
  SENTINELFORGE_REF, SENTINELFORGE_ASSETS_DIR, SENTINELFORGE_HEALTH_TIMEOUT,
  SENTINELFORGE_VERIFY_TIMEOUT, SENTINELFORGE_SKIP_PULL,
  SENTINELFORGE_SKIP_MIGRATIONS

Examples:
  # Install from a Git checkout (recommended while developing)
  ./scripts/install.sh

  # Install on a custom port, reachable from the local network (firewall first)
  ./scripts/install.sh --port 8080 --bind 0.0.0.0

  # Re-run safely after editing image tags in ~/.sentinelforge/.env
  ./scripts/install.sh

Once the official installer URL is published, remote installation will be:
  curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<ref>/scripts/install.sh | bash

The installer never prints secrets and never exposes PostgreSQL or Redis.
EOF
}

# ------------------------------------------------------------------------------
# Small helpers
# ------------------------------------------------------------------------------
env_value() {
    # Print one value from a KEY=VALUE file without sourcing it.
    local file="$1" key="$2"
    awk -v key="$key" '
        BEGIN { FS = "=" }
        $1 == key {
            sub(/^[^=]*=/, "")
            sub(/\r$/, "")
            print
            exit
        }
    ' "$file"
}

file_mode() {
    local file="$1"
    case "$OS_FAMILY" in
        darwin) stat -f '%Lp' "$file" 2>/dev/null || true ;;
        *) stat -c '%a' "$file" 2>/dev/null || true ;;
    esac
}

generate_secret() {
    # Hex output is URL-safe and safe inside DSNs and env files.
    local bytes="$1" value
    if command -v openssl >/dev/null 2>&1; then
        value=$(openssl rand -hex "$bytes" 2>/dev/null) || return 1
    elif command -v python3 >/dev/null 2>&1; then
        value=$(python3 -c 'import secrets, sys; sys.stdout.write(secrets.token_hex(int(sys.argv[1])))' "$bytes" 2>/dev/null) || return 1
    else
        return 1
    fi
    printf '%s' "$value"
}

is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_ipv4() {
    local ip="$1" IFS=. octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    for octet in $ip; do
        (( 10#$octet <= 255 )) || return 1
    done
    return 0
}

# ------------------------------------------------------------------------------
# Argument parsing and validation
# ------------------------------------------------------------------------------
parse_args() {
    [[ -n "${SENTINELFORGE_SKIP_PULL:-}" ]] && is_true "$SENTINELFORGE_SKIP_PULL" && SKIP_PULL=true
    [[ -n "${SENTINELFORGE_SKIP_MIGRATIONS:-}" ]] && is_true "$SENTINELFORGE_SKIP_MIGRATIONS" && SKIP_MIGRATIONS=true

    [[ -n "${SENTINELFORGE_PROJECT:-}" ]] && PROJECT_SET=true
    [[ -n "${SENTINELFORGE_PORT:-}" ]] && PORT_SET=true
    [[ -n "${SENTINELFORGE_BIND:-}" ]] && BIND_SET=true
    [[ -n "${SENTINELFORGE_TAG:-}" ]] && TAG_SET=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir)
                [[ $# -ge 2 && -n "$2" ]] || die_usage "--dir requires a path"
                INSTALL_DIR="$2"
                shift 2
                ;;
            --dir=*)
                INSTALL_DIR="${1#*=}"
                [[ -n "$INSTALL_DIR" ]] || die_usage "--dir requires a path"
                shift
                ;;
            --port)
                [[ $# -ge 2 && -n "$2" ]] || die_usage "--port requires a value"
                PORT="$2"
                PORT_SET=true
                shift 2
                ;;
            --port=*)
                PORT="${1#*=}"
                PORT_SET=true
                shift
                ;;
            --bind)
                [[ $# -ge 2 && -n "$2" ]] || die_usage "--bind requires a value"
                BIND_ADDRESS="$2"
                BIND_SET=true
                shift 2
                ;;
            --bind=*)
                BIND_ADDRESS="${1#*=}"
                BIND_SET=true
                shift
                ;;
            --project-name)
                [[ $# -ge 2 && -n "$2" ]] || die_usage "--project-name requires a value"
                PROJECT="$2"
                PROJECT_SET=true
                shift 2
                ;;
            --project-name=*)
                PROJECT="${1#*=}"
                PROJECT_SET=true
                shift
                ;;
            --tag)
                [[ $# -ge 2 && -n "$2" ]] || die_usage "--tag requires a value"
                IMAGE_TAG="$2"
                TAG_SET=true
                shift 2
                ;;
            --tag=*)
                IMAGE_TAG="${1#*=}"
                TAG_SET=true
                shift
                ;;
            --ref)
                [[ $# -ge 2 && -n "$2" ]] || die_usage "--ref requires a value"
                REPO_REF="$2"
                shift 2
                ;;
            --ref=*)
                REPO_REF="${1#*=}"
                shift
                ;;
            --assets-dir)
                [[ $# -ge 2 && -n "$2" ]] || die_usage "--assets-dir requires a path"
                ASSETS_DIR_OVERRIDE="$2"
                shift 2
                ;;
            --assets-dir=*)
                ASSETS_DIR_OVERRIDE="${1#*=}"
                shift
                ;;
            --skip-pull)
                SKIP_PULL=true
                shift
                ;;
            --skip-migrations)
                SKIP_MIGRATIONS=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --version)
                printf 'SentinelForge installer %s\n' "$INSTALLER_VERSION"
                exit 0
                ;;
            *)
                die_usage "Unknown option: $1"
                ;;
        esac
    done

    validate_options
}

validate_options() {
    local tilde='~'

    # Expand a leading ~/ without invoking eval.
    case "$INSTALL_DIR" in
        "$tilde") INSTALL_DIR="$HOME" ;;
        "$tilde/"*) INSTALL_DIR="${HOME}/${INSTALL_DIR#"$tilde/"}" ;;
    esac
    case "$INSTALL_DIR" in
        /*) ;;
        *) INSTALL_DIR="$(pwd -P)/${INSTALL_DIR}" ;;
    esac

    [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || die_usage "Invalid --port: must be a number between 1 and 65535"
    if (( PORT < 1 || PORT > 65535 )); then
        die_usage "Invalid --port: must be between 1 and 65535"
    fi

    is_valid_ipv4 "$BIND_ADDRESS" \
        || die_usage "Invalid --bind: an IPv4 address is required (e.g. 127.0.0.1)"

    [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
        || die_usage "Invalid --project-name: use lowercase letters, digits, '-' or '_'"

    [[ "$IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] \
        || die_usage "Invalid --tag: unsupported characters"

    [[ "$REPO_SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || die_usage "Invalid SENTINELFORGE_REPO: expected 'owner/repository'"
    case "$REPO_SLUG" in
        *..*) die_usage "Invalid SENTINELFORGE_REPO: '..' is not allowed" ;;
    esac

    [[ "$REPO_REF" =~ ^[A-Za-z0-9._/-]+$ ]] \
        || die_usage "Invalid SENTINELFORGE_REF: unsupported characters"
    case "$REPO_REF" in
        *..*) die_usage "Invalid SENTINELFORGE_REF: '..' is not allowed" ;;
    esac

    [[ "$HEALTH_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] \
        || die_usage "Invalid SENTINELFORGE_HEALTH_TIMEOUT: expected seconds"

    [[ "$VERIFY_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] \
        || die_usage "Invalid SENTINELFORGE_VERIFY_TIMEOUT: expected seconds"

    if [[ -n "$ASSETS_DIR_OVERRIDE" ]]; then
        [[ -d "$ASSETS_DIR_OVERRIDE" ]] \
            || die_usage "--assets-dir does not exist: $ASSETS_DIR_OVERRIDE"
        ASSETS_DIR_OVERRIDE="$(cd "$ASSETS_DIR_OVERRIDE" && pwd -P)"
    fi
}

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
detect_platform() {
    local kernel arch
    kernel=$(uname -s 2>/dev/null || printf 'unknown')
    arch=$(uname -m 2>/dev/null || printf 'unknown')

    case "$kernel" in
        Linux)
            OS_FAMILY="linux"
            if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; then
                IS_WSL=true
                log_info "WSL2 detected. Docker Desktop WSL integration must be enabled."
            fi
            ;;
        Darwin)
            OS_FAMILY="darwin"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            die "Windows shells are not supported. Run this installer inside WSL2 (Ubuntu) or on Linux/macOS."
            ;;
        *)
            die "Unsupported operating system: ${kernel}. Supported: Linux, macOS and WSL2."
            ;;
    esac

    case "$arch" in
        x86_64|amd64) ;;
        aarch64|arm64)
            log_warn "Published SentinelForge images are currently amd64-only; this arm64 host will use Docker emulation."
            ;;
        *) log_warn "Architecture '${arch}' is untested with the published images." ;;
    esac
}

check_docker() {
    command -v docker >/dev/null 2>&1 \
        || die "Docker is not installed. Install Docker Engine or Docker Desktop and re-run."

    local compose_version compose_major
    if compose_version=$(docker compose version --short 2>/dev/null); then
        :
    elif compose_version=$(docker compose version 2>/dev/null | head -n 1); then
        :
    else
        if command -v docker-compose >/dev/null 2>&1; then
            die "Docker Compose v1 was found. SentinelForge requires the Docker Compose v2 plugin ('docker compose'). See docs/installation.md#requirements."
        fi
        die "Docker Compose v2 is not available. Install the Docker Compose plugin and re-run."
    fi

    compose_major=$(printf '%s' "$compose_version" | sed -n -e 's/^\([0-9][0-9]*\).*/\1/p' -e 's/.*[vV]\([0-9][0-9]*\).*/\1/p' | head -n 1)
    if [[ -n "$compose_major" ]] && (( compose_major < COMPOSE_VERSION_MIN_MAJOR )); then
        die "Docker Compose ${compose_version} is too old. Version 2 or newer is required."
    fi

    if ! docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
        die "The Docker daemon is not running or not reachable. Start Docker and ensure your user can access it (see docs/installation.md#troubleshooting)."
    fi

    log_success "Docker and Docker Compose are available."
}

nearest_existing_path() {
    local path="$1"
    while [[ ! -e "$path" ]]; do
        if [[ "$path" == "/" || -z "$path" ]]; then
            printf '/'
            return 0
        fi
        path=$(dirname "$path")
    done
    printf '%s' "$path"
}

windows_drive_free_mb() {
    local mount
    for mount in /mnt/c /mnt/C; do
        if [[ -d "$mount" ]]; then
            df -Pk "$mount" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 }'
            return 0
        fi
    done
    return 1
}

check_disk_space() {
    local probe available_kb available_mb windows_mb=""
    probe=$(nearest_existing_path "$INSTALL_DIR")

    if ! command -v df >/dev/null 2>&1; then
        log_warn "df is unavailable; skipping disk space check."
        return 0
    fi

    available_kb=$(df -Pk "$probe" 2>/dev/null | awk 'NR == 2 { print $4 }')
    if [[ ! "$available_kb" =~ ^[0-9]+$ ]]; then
        log_warn "Could not determine available disk space; continuing."
        return 0
    fi

    available_mb=$((available_kb / 1024))

    # With Docker Desktop on WSL2 the images and named volumes live in a VM on
    # the Windows host, so free space inside the WSL filesystem is misleading.
    # Refusing to install there would block otherwise valid installations.
    if [[ "$IS_WSL" == "true" ]] \
        && docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi 'docker desktop'; then
        if windows_mb=$(windows_drive_free_mb) && [[ "$windows_mb" =~ ^[0-9]+$ ]]; then
            if (( windows_mb < MIN_DISK_MB )); then
                log_warn "Only ${windows_mb} MB free on the Windows drive that hosts Docker Desktop data."
            else
                log_success "Disk space: ${available_mb} MB in WSL, ${windows_mb} MB on the Windows drive hosting Docker data."
            fi
        else
            log_warn "Docker Desktop on WSL2 stores images and volumes on the Windows host, not in this filesystem (${available_mb} MB free here)."
        fi
        return 0
    fi

    if (( available_mb < MIN_DISK_MB )); then
        die "Not enough disk space at ${probe}: ${available_mb} MB available, ${MIN_DISK_MB} MB required."
    fi
    if (( available_mb < RECOMMENDED_DISK_MB )); then
        log_warn "Only ${available_mb} MB free; ${RECOMMENDED_DISK_MB} MB is recommended for images, database growth and backups."
    else
        log_success "Disk space: ${available_mb} MB available."
    fi
}

check_prerequisites() {
    command -v curl >/dev/null 2>&1 \
        || die "curl is required for download and health checks. Install curl and re-run."
    command -v awk >/dev/null 2>&1 \
        || die "awk is required. Install awk and re-run."
    command -v mktemp >/dev/null 2>&1 \
        || die "mktemp is required. Install coreutils and re-run."
    command -v cmp >/dev/null 2>&1 \
        || die "cmp is required. Install diffutils/coreutils and re-run."
    command -v install >/dev/null 2>&1 \
        || die "install is required. Install coreutils and re-run."
    command -v sed >/dev/null 2>&1 \
        || die "sed is required. Install sed and re-run."
}

# ------------------------------------------------------------------------------
# Install directory, locking and assets
# ------------------------------------------------------------------------------
prepare_install_dir() {
    if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ]]; then
        die "Installation path exists and is not a directory: ${INSTALL_DIR}"
    fi

    mkdir -p "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"

    # Resolve symlinks so Docker receives a stable absolute path.
    INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
    ENV_FILE="${INSTALL_DIR}/.env"

    TMP_WORK=$(mktemp -d "${TMPDIR:-/tmp}/sentinelforge.XXXXXX") \
        || die "Unable to create a temporary directory."

    log_success "Installation directory: ${INSTALL_DIR}"
}

acquire_lock() {
    local lock_file="${INSTALL_DIR}/.install.lock"

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$lock_file"
        chmod 600 "$lock_file"
        if ! flock -n 9; then
            die "Another SentinelForge installer is already running (lock: ${lock_file})."
        fi
        LOCK_ACQUIRED=true
        return 0
    fi

    LOCK_DIR="${INSTALL_DIR}/.install.lock.d"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        local existing_pid=""
        existing_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            die "Another SentinelForge installer is already running (pid ${existing_pid})."
        fi
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" || die "Unable to acquire the installation lock."
    fi
    printf '%s\n' "$$" > "${LOCK_DIR}/pid"
    LOCK_ACQUIRED=true
}

resolve_local_assets() {
    local script_path="${BASH_SOURCE[0]:-}"
    local script_dir=""

    if [[ -n "$script_path" && -f "$script_path" ]]; then
        script_dir=$(cd "$(dirname "$script_path")" && pwd -P)
    fi

    if [[ -n "$ASSETS_DIR_OVERRIDE" ]]; then
        ASSETS_SRC="$ASSETS_DIR_OVERRIDE"
        return 0
    fi

    if [[ -n "$script_dir" && -f "${script_dir}/../deploy/docker-compose.yml" ]]; then
        ASSETS_SRC=$(cd "${script_dir}/../deploy" && pwd -P)
        return 0
    fi

    return 1
}

download_assets() {
    local dest="$1" base_url rel url

    base_url="https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}/deploy"
    mkdir -p "${dest}/config"

    for rel in docker-compose.yml .env.example config/nginx.conf; do
        url="${base_url}/${rel}"
        log_info "Downloading ${rel}..."
        if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 \
            -o "${dest}/${rel}" "$url"; then
            return 1
        fi
    done
    return 0
}

prepare_assets() {
    local download_dir

    if resolve_local_assets; then
        log_info "Using deployment assets from: ${ASSETS_SRC}"
        return 0
    fi

    download_dir="${TMP_WORK}/assets"
    if download_assets "$download_dir"; then
        ASSETS_SRC="$download_dir"
        return 0
    fi

    if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
        log_warn "Asset download failed. Continuing with the deployment files already present in ${INSTALL_DIR}."
        ASSETS_SRC=""
        return 0
    fi

    die "Unable to obtain deployment assets. Check network access, or run the installer from a Git checkout with --assets-dir."
}

install_file_if_changed() {
    local src="$1" dest="$2" mode="$3" backup

    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        return 0
    fi

    if [[ -f "$dest" ]]; then
        backup="${dest}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        cp -p "$dest" "$backup" || die "Unable to back up ${dest}."
        log_warn "Updated $(basename "$dest"); previous version saved as $(basename "$backup")."
    fi

    install -m "$mode" "$src" "$dest" || die "Unable to install ${dest}."
}

install_assets() {
    [[ -n "$ASSETS_SRC" ]] || return 0

    [[ -f "${ASSETS_SRC}/docker-compose.yml" ]] || die "Deployment assets are incomplete: missing docker-compose.yml"
    [[ -f "${ASSETS_SRC}/.env.example" ]] || die "Deployment assets are incomplete: missing .env.example"

    install_file_if_changed "${ASSETS_SRC}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml" 0644
    install_file_if_changed "${ASSETS_SRC}/.env.example" "${INSTALL_DIR}/.env.example" 0644

    if [[ -f "${ASSETS_SRC}/config/nginx.conf" ]]; then
        mkdir -p "${INSTALL_DIR}/config"
        chmod 700 "${INSTALL_DIR}/config"
        install_file_if_changed "${ASSETS_SRC}/config/nginx.conf" "${INSTALL_DIR}/config/nginx.conf" 0644
    else
        die "Deployment assets are incomplete: missing config/nginx.conf"
    fi

    printf '%s\n' "$INSTALLER_VERSION" > "${INSTALL_DIR}/.installer-version"
    chmod 600 "${INSTALL_DIR}/.installer-version"

    log_success "Deployment configuration installed."
}

# ------------------------------------------------------------------------------
# Environment file generation and validation
# ------------------------------------------------------------------------------
write_env_file() {
    local db_password jwt_secret tmp_file

    db_password=$(generate_secret 32) \
        || die "Unable to generate secrets: install openssl or python3."
    jwt_secret=$(generate_secret 32) \
        || die "Unable to generate secrets: install openssl or python3."

    [[ "$db_password" =~ ^[0-9a-f]{64}$ ]] || die "Secret generation returned unexpected data."
    [[ "$jwt_secret" =~ ^[0-9a-f]{64}$ ]] || die "Secret generation returned unexpected data."

    tmp_file=$(mktemp "${INSTALL_DIR}/.env.XXXXXX") \
        || die "Unable to create the environment file."

    if ! (
        umask 077
        {
            printf '%s\n' \
                "# ==============================================================================" \
                "# SentinelForge environment configuration (generated by install.sh)" \
                "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "#" \
                "# WARNING: This file contains secrets." \
                "#   * Keep permissions at 0600." \
                "#   * Never commit it to version control." \
                "#   * Never paste its contents into issues or chat." \
                "#" \
                "# PostgreSQL credentials are read only when the data volume is first" \
                "# initialized. Changing POSTGRES_USER, POSTGRES_DB or POSTGRES_PASSWORD" \
                "# afterwards requires changes inside PostgreSQL, or the backend will" \
                "# fail to authenticate." \
                "# ==============================================================================" \
                "" \
                "# Docker Compose / gateway" \
                "COMPOSE_PROJECT_NAME=${PROJECT}" \
                "SENTINELFORGE_PORT=${PORT}" \
                "SENTINELFORGE_BIND=${BIND_ADDRESS}" \
                "" \
                "# Container images (pin a release tag for reproducible deployments)" \
                "SENTINELFORGE_BACKEND_IMAGE=${BACKEND_IMAGE_REPO}:${IMAGE_TAG}" \
                "SENTINELFORGE_FRONTEND_IMAGE=${FRONTEND_IMAGE_REPO}:${IMAGE_TAG}" \
                "SENTINELFORGE_GATEWAY_IMAGE=${DEFAULT_GATEWAY_IMAGE}" \
                "" \
                "# PostgreSQL (internal network only, never published to the host)" \
                "POSTGRES_USER=sentinelforge" \
                "POSTGRES_PASSWORD=${db_password}" \
                "POSTGRES_DB=sentinelforge" \
                "" \
                "# Backend authentication" \
                "JWT_SECRET_KEY=${jwt_secret}" \
                "JWT_ALGORITHM=HS256" \
                "ACCESS_TOKEN_EXPIRE_MINUTES=15" \
                "REFRESH_TOKEN_EXPIRE_DAYS=7"
        } > "$tmp_file"
    ); then
        rm -f "$tmp_file"
        die "Unable to write the environment file."
    fi

    chmod 600 "$tmp_file"
    mv -f "$tmp_file" "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    unset db_password jwt_secret
    log_success "Generated cryptographically secure secrets (values not displayed)."
}

set_env_value() {
    # Update a single, non-secret configuration value atomically.
    local file="$1" key="$2" value="$3" tmp_file
    tmp_file=$(mktemp "${file}.XXXXXX") || return 1
    chmod 600 "$tmp_file"
    if ! awk -v k="$key" -v v="$value" '
        BEGIN { done = 0 }
        index($0, k "=") == 1 { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$file" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    mv -f "$tmp_file" "$file"
    chmod 600 "$file"
}

validate_env_file() {
    local user password database jwt algorithm access_days refresh_days
    local project_value port_value bind_value backend_image frontend_image gateway_image

    [[ -f "$ENV_FILE" ]] || die "Environment file is missing: ${ENV_FILE} (refusing to regenerate over existing data)."

    user=$(env_value "$ENV_FILE" POSTGRES_USER)
    password=$(env_value "$ENV_FILE" POSTGRES_PASSWORD)
    database=$(env_value "$ENV_FILE" POSTGRES_DB)
    jwt=$(env_value "$ENV_FILE" JWT_SECRET_KEY)
    algorithm=$(env_value "$ENV_FILE" JWT_ALGORITHM)
    access_days=$(env_value "$ENV_FILE" ACCESS_TOKEN_EXPIRE_MINUTES)
    refresh_days=$(env_value "$ENV_FILE" REFRESH_TOKEN_EXPIRE_DAYS)
    project_value=$(env_value "$ENV_FILE" COMPOSE_PROJECT_NAME)
    port_value=$(env_value "$ENV_FILE" SENTINELFORGE_PORT)
    bind_value=$(env_value "$ENV_FILE" SENTINELFORGE_BIND)
    backend_image=$(env_value "$ENV_FILE" SENTINELFORGE_BACKEND_IMAGE)
    frontend_image=$(env_value "$ENV_FILE" SENTINELFORGE_FRONTEND_IMAGE)
    gateway_image=$(env_value "$ENV_FILE" SENTINELFORGE_GATEWAY_IMAGE)

    [[ -n "$user" ]] || die "Environment validation failed: POSTGRES_USER is empty."
    [[ "$user" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] \
        || die "Environment validation failed: POSTGRES_USER is not a valid identifier."

    [[ -n "$password" ]] || die "Environment validation failed: POSTGRES_PASSWORD is empty."
    [[ "$password" =~ ^[A-Za-z0-9._~-]+$ ]] \
        || die "Environment validation failed: POSTGRES_PASSWORD must contain only URL-safe characters."
    if (( ${#password} < 32 )); then
        die "Environment validation failed: POSTGRES_PASSWORD must be at least 32 characters. Refusing to start with a weak database password."
    fi
    local password_lc
    password_lc=$(printf '%s' "$password" | tr '[:upper:]' '[:lower:]')
    case "$password_lc" in
        *change*|*sentinelforge*|*replace_with*) die "Environment validation failed: POSTGRES_PASSWORD still contains a placeholder value." ;;
    esac

    [[ -n "$database" ]] || die "Environment validation failed: POSTGRES_DB is empty."
    [[ "$database" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] \
        || die "Environment validation failed: POSTGRES_DB is not a valid identifier."

    [[ -n "$jwt" ]] || die "Environment validation failed: JWT_SECRET_KEY is empty."
    [[ "$jwt" =~ ^[A-Za-z0-9._~-]+$ ]] \
        || die "Environment validation failed: JWT_SECRET_KEY must contain only URL-safe characters."
    case "$jwt" in
        *change_this*|*replace_with*|*changeme*) die "Environment validation failed: JWT_SECRET_KEY still contains a placeholder value." ;;
    esac
    if (( ${#jwt} < 32 )); then
        die "Environment validation failed: JWT_SECRET_KEY must be at least 32 characters."
    fi

    [[ "$algorithm" == "HS256" ]] || log_warn "JWT_ALGORITHM is '${algorithm}'; HS256 is the tested value."

    [[ "$access_days" =~ ^[0-9]+$ ]] \
        || die "Environment validation failed: ACCESS_TOKEN_EXPIRE_MINUTES must be numeric."
    [[ "$refresh_days" =~ ^[0-9]+$ ]] \
        || die "Environment validation failed: REFRESH_TOKEN_EXPIRE_DAYS must be numeric."

    [[ -n "$project_value" ]] || die "Environment validation failed: COMPOSE_PROJECT_NAME is empty."
    [[ "$project_value" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
        || die "Environment validation failed: COMPOSE_PROJECT_NAME is invalid."

    [[ "$port_value" =~ ^[1-9][0-9]{0,4}$ ]] && (( port_value >= 1 && port_value <= 65535 )) \
        || die "Environment validation failed: SENTINELFORGE_PORT is invalid."
    is_valid_ipv4 "$bind_value" \
        || die "Environment validation failed: SENTINELFORGE_BIND is invalid."

    [[ -n "$backend_image" && -n "$frontend_image" && -n "$gateway_image" ]] \
        || die "Environment validation failed: container image references are missing."
    local image
    for image in "$backend_image" "$frontend_image" "$gateway_image"; do
        [[ "$image" =~ ^[A-Za-z0-9._/:@-]+$ ]] \
            || die "Environment validation failed: invalid container image reference."
    done

    local mode
    mode=$(file_mode "$ENV_FILE")
    if [[ "$mode" != "600" ]]; then
        log_warn "Environment file permissions are ${mode:-unknown}; tightening to 600."
        chmod 600 "$ENV_FILE" 2>/dev/null \
            || die "Unable to set permissions 0600 on ${ENV_FILE}. Fix ownership and re-run."
    fi
}

load_existing_settings() {
    [[ -f "$ENV_FILE" ]] || return 0

    local stored_project stored_port stored_bind stored_backend stored_frontend stored_gateway
    local new_backend new_frontend

    stored_project=$(env_value "$ENV_FILE" COMPOSE_PROJECT_NAME)
    stored_port=$(env_value "$ENV_FILE" SENTINELFORGE_PORT)
    stored_bind=$(env_value "$ENV_FILE" SENTINELFORGE_BIND)
    stored_backend=$(env_value "$ENV_FILE" SENTINELFORGE_BACKEND_IMAGE)
    stored_frontend=$(env_value "$ENV_FILE" SENTINELFORGE_FRONTEND_IMAGE)
    stored_gateway=$(env_value "$ENV_FILE" SENTINELFORGE_GATEWAY_IMAGE)

    if [[ "$PROJECT_SET" == "true" && -n "$stored_project" && "$stored_project" != "$PROJECT" ]]; then
        die "This installation already uses project '${stored_project}'. Changing the project name would orphan its volumes. Refusing to continue."
    fi

    if [[ "$PROJECT_SET" != "true" && -n "$stored_project" ]]; then
        PROJECT="$stored_project"
    fi

    # Backfill optional, non-secret settings for configurations created by an
    # older installer or edited by hand. Secrets are never regenerated here.
    if [[ -z "$stored_project" ]]; then
        set_env_value "$ENV_FILE" COMPOSE_PROJECT_NAME "$PROJECT" \
            || die "Unable to add COMPOSE_PROJECT_NAME to the environment file."
        log_warn "Added missing COMPOSE_PROJECT_NAME to the existing configuration (secrets unchanged)."
    fi
    if [[ -z "$stored_port" ]]; then
        set_env_value "$ENV_FILE" SENTINELFORGE_PORT "$PORT" \
            || die "Unable to add SENTINELFORGE_PORT to the environment file."
        stored_port="$PORT"
        log_warn "Added missing SENTINELFORGE_PORT to the existing configuration (secrets unchanged)."
    fi
    if [[ -z "$stored_bind" ]]; then
        set_env_value "$ENV_FILE" SENTINELFORGE_BIND "$BIND_ADDRESS" \
            || die "Unable to add SENTINELFORGE_BIND to the environment file."
        stored_bind="$BIND_ADDRESS"
        log_warn "Added missing SENTINELFORGE_BIND to the existing configuration (secrets unchanged)."
    fi
    if [[ -z "$stored_backend" ]]; then
        set_env_value "$ENV_FILE" SENTINELFORGE_BACKEND_IMAGE "${BACKEND_IMAGE_REPO}:${IMAGE_TAG}" \
            || die "Unable to add SENTINELFORGE_BACKEND_IMAGE to the environment file."
        stored_backend="${BACKEND_IMAGE_REPO}:${IMAGE_TAG}"
        log_warn "Added missing SENTINELFORGE_BACKEND_IMAGE to the existing configuration (secrets unchanged)."
    fi
    if [[ -z "$stored_frontend" ]]; then
        set_env_value "$ENV_FILE" SENTINELFORGE_FRONTEND_IMAGE "${FRONTEND_IMAGE_REPO}:${IMAGE_TAG}" \
            || die "Unable to add SENTINELFORGE_FRONTEND_IMAGE to the environment file."
        stored_frontend="${FRONTEND_IMAGE_REPO}:${IMAGE_TAG}"
        log_warn "Added missing SENTINELFORGE_FRONTEND_IMAGE to the existing configuration (secrets unchanged)."
    fi
    if [[ -z "$stored_gateway" ]]; then
        set_env_value "$ENV_FILE" SENTINELFORGE_GATEWAY_IMAGE "$DEFAULT_GATEWAY_IMAGE" \
            || die "Unable to add SENTINELFORGE_GATEWAY_IMAGE to the environment file."
        log_warn "Added missing SENTINELFORGE_GATEWAY_IMAGE to the existing configuration (secrets unchanged)."
    fi

    if [[ "$PORT_SET" != "true" && -n "$stored_port" ]]; then
        PORT="$stored_port"
    fi
    if [[ "$BIND_SET" != "true" && -n "$stored_bind" ]]; then
        BIND_ADDRESS="$stored_bind"
    fi

    validate_env_file

    # Persist explicitly requested, non-secret updates.
    if [[ "$PORT_SET" == "true" && "$stored_port" != "$PORT" ]]; then
        set_env_value "$ENV_FILE" SENTINELFORGE_PORT "$PORT" \
            || die "Unable to update SENTINELFORGE_PORT in the environment file."
        log_warn "Gateway port changed to ${PORT} in the existing configuration."
    fi
    if [[ "$BIND_SET" == "true" && "$stored_bind" != "$BIND_ADDRESS" ]]; then
        set_env_value "$ENV_FILE" SENTINELFORGE_BIND "$BIND_ADDRESS" \
            || die "Unable to update SENTINELFORGE_BIND in the environment file."
        log_warn "Gateway bind address changed to ${BIND_ADDRESS} in the existing configuration."
    fi

    if [[ "$TAG_SET" == "true" ]]; then
        new_backend="${BACKEND_IMAGE_REPO}:${IMAGE_TAG}"
        new_frontend="${FRONTEND_IMAGE_REPO}:${IMAGE_TAG}"
        if [[ "$stored_backend" != "$new_backend" || "$stored_frontend" != "$new_frontend" ]]; then
            set_env_value "$ENV_FILE" SENTINELFORGE_BACKEND_IMAGE "$new_backend" \
                || die "Unable to update SENTINELFORGE_BACKEND_IMAGE."
            set_env_value "$ENV_FILE" SENTINELFORGE_FRONTEND_IMAGE "$new_frontend" \
                || die "Unable to update SENTINELFORGE_FRONTEND_IMAGE."
            log_warn "Image tag updated to '${IMAGE_TAG}' in the existing configuration (no secrets modified)."
        fi
    fi
}

detect_existing_state() {
    [[ -f "$ENV_FILE" ]] && return 0

    local volume_name="${PROJECT}_postgres_data" volume_match containers
    volume_match=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -Fx "$volume_name" || true)
    containers=$(docker ps -a --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Names}}' 2>/dev/null | head -n 5 || true)

    if [[ -n "$volume_match" || -n "$containers" ]]; then
        cat >&2 <<EOF
${RED}[FAIL]${NC} Existing SentinelForge resources were found for project '${PROJECT}', but no
       environment file exists at:
           ${ENV_FILE}

       Refusing to generate new credentials: a new database password would not
       match the existing PostgreSQL data volume and existing users, audit logs
       and security alerts would become inaccessible.

       Recovery options:
         1. Restore the .env file from your backup and re-run the installer.
         2. If you know the original database password, create ${ENV_FILE}
            manually with the matching POSTGRES_PASSWORD and a JWT_SECRET_KEY.
         3. To intentionally discard existing data, use the documented purge
            procedure: scripts/uninstall.sh --purge-data
EOF
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Docker Compose operations
# ------------------------------------------------------------------------------
sanitize_compose_environment() {
    # Docker Compose gives shell environment variables precedence over --env-file.
    # Remove any conflicting values so the validated installation .env is the
    # single source of truth. Installer options were already captured above.
    unset POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB \
        JWT_SECRET_KEY JWT_ALGORITHM \
        ACCESS_TOKEN_EXPIRE_MINUTES REFRESH_TOKEN_EXPIRE_DAYS \
        SENTINELFORGE_BACKEND_IMAGE SENTINELFORGE_FRONTEND_IMAGE \
        SENTINELFORGE_GATEWAY_IMAGE SENTINELFORGE_PORT SENTINELFORGE_BIND \
        COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_PROFILES COMPOSE_ENV_FILES
}

compose() {
    docker compose \
        --project-directory "$INSTALL_DIR" \
        --env-file "$ENV_FILE" \
        --project-name "$PROJECT" \
        -f "${INSTALL_DIR}/docker-compose.yml" \
        "$@"
}

validate_compose_config() {
    log_info "Validating deployment configuration..."
    if ! compose config --quiet >/dev/null 2>"${TMP_WORK}/compose-config.err"; then
        die "Deployment configuration is invalid. Run 'docker compose config' in ${INSTALL_DIR} for details."
    fi
    log_success "Deployment configuration is valid."
}

check_port_available() {
    local ports probe_host="$BIND_ADDRESS"
    [[ "$probe_host" == "0.0.0.0" ]] && probe_host="127.0.0.1"

    if ! (exec 3<>"/dev/tcp/${probe_host}/${PORT}") 2>/dev/null; then
        return 0
    fi

    ports=$(docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Ports}}' 2>/dev/null || true)
    if [[ "$ports" == *":${PORT}->"* ]]; then
        log_info "Port ${PORT} is already used by this SentinelForge installation."
        return 0
    fi

    die "TCP port ${PORT} is already in use on ${probe_host}. Choose another port with --port."
}

pull_images() {
    if [[ "$SKIP_PULL" == "true" ]]; then
        log_warn "Skipping image pull as requested (--skip-pull)."
        return 0
    fi

    log_info "Pulling container images..."
    if ! compose pull --quiet postgres redis backend frontend gateway; then
        die "Unable to pull images. Check network access and image availability, or re-run with --skip-pull for locally built images."
    fi
    log_success "Container images are up to date."
}

container_id_for() {
    compose ps -q "$1" 2>/dev/null | head -n 1 || true
}

show_service_logs() {
    local service="$1"
    local log_file="${TMP_WORK}/service-${service}.log"
    local password="" jwt=""

    printf '\n--- last 50 log lines: %s (secrets redacted) ---\n' "$service" >&2
    compose logs --no-color --tail=50 "$service" >"$log_file" 2>&1 || true

    if [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]]; then
        password=$(env_value "$ENV_FILE" POSTGRES_PASSWORD 2>/dev/null || true)
        jwt=$(env_value "$ENV_FILE" JWT_SECRET_KEY 2>/dev/null || true)
    fi

    {
        if [[ -n "$password" ]]; then
            sed "s|${password}|[REDACTED]|g" "$log_file"
        else
            cat "$log_file"
        fi
    } | {
        if [[ -n "$jwt" ]]; then
            sed "s|${jwt}|[REDACTED]|g"
        else
            cat
        fi
    } | sed -E 's#(postgresql\+asyncpg://)[^@[:space:]]*@#\1[REDACTED]@#g' >&2 || true

    printf '%s\n' "--- end of logs ---" >&2
}

wait_for_health() {
    local service="$1"
    local timeout="${2:-$HEALTH_TIMEOUT}"
    local elapsed=0 container_id status

    log_info "Waiting for ${service} to become healthy..."
    while :; do
        container_id=$(container_id_for "$service")
        if [[ -n "$container_id" ]]; then
            status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)
            case "$status" in
                healthy)
                    log_success "${service} is healthy."
                    return 0
                    ;;
                exited|dead)
                    show_service_logs "$service"
                    die "${service} stopped unexpectedly. Inspect logs with: docker compose -p ${PROJECT} -f ${INSTALL_DIR}/docker-compose.yml logs ${service}"
                    ;;
            esac
        fi

        if (( elapsed >= timeout )); then
            show_service_logs "$service"
            die "Timed out after ${timeout}s waiting for ${service} to become healthy."
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
}

run_migrations() {
    local log_file="${TMP_WORK}/migrate.log"
    local pass_file="${TMP_WORK}/.db-password" jwt_file="${TMP_WORK}/.jwt-secret"

    if [[ "$SKIP_MIGRATIONS" == "true" ]]; then
        log_warn "Skipping database migrations as requested (--skip-migrations). The backend may fail if the schema is outdated."
        return 0
    fi

    log_info "Applying database migrations..."
    if compose --profile tools run --rm --no-deps -T migrate >"$log_file" 2>&1; then
        log_success "Database migrations are up to date."
        return 0
    fi

    # Never echo output that may contain credentials.
    env_value "$ENV_FILE" POSTGRES_PASSWORD > "$pass_file"
    env_value "$ENV_FILE" JWT_SECRET_KEY > "$jwt_file"
    chmod 600 "$pass_file" "$jwt_file"

    if grep -Fq -f "$pass_file" "$log_file" || grep -Fq -f "$jwt_file" "$log_file"; then
        rm -f "$pass_file" "$jwt_file"
        die "Database migration failed. Output was suppressed because it may contain credentials. Re-run manually with: docker compose -p ${PROJECT} -f ${INSTALL_DIR}/docker-compose.yml --profile tools run --rm migrate"
    fi

    rm -f "$pass_file" "$jwt_file"
    printf '\n--- migration output (tail) ---\n' >&2
    tail -n 40 "$log_file" >&2 || true
    printf '%s\n' "--- end of migration output ---" >&2

    # The container may run a backend image that was published before the
    # Alembic directory was added to the Dockerfile. Detect that specific,
    # actionable failure instead of leaving the operator guessing.
    if grep -Eq "alembic\.ini|script_location|No such file or directory" "$log_file" 2>/dev/null; then
        log_warn "The backend image does not appear to contain Alembic migrations."
        log_warn "Images published before Alembic support was added to backend/Dockerfile cannot run 'alembic upgrade head'."
        log_warn "Use a backend image built from this branch (CI publishes it), or rebuild it locally:"
        log_warn "  docker build -t ${BACKEND_IMAGE_REPO}:local backend"
        log_warn "Then set SENTINELFORGE_BACKEND_IMAGE=${BACKEND_IMAGE_REPO}:local in ${ENV_FILE} and re-run."
    fi

    die "Database migration failed. Fix the error above and re-run the installer."
}

verify_backend_health() {
    local elapsed=0 output

    log_info "Verifying backend health..."
    while :; do
        output=$(compose exec -T backend python -c \
            'import json, urllib.request; data = json.load(urllib.request.urlopen("http://127.0.0.1:8000/health", timeout=5)); print(data.get("status", "unknown"))' \
            2>/dev/null | tr -d '\r' || true)

        if [[ "$output" == *"healthy"* ]]; then
            log_success "Backend health: healthy (database and Redis reachable)."
            return 0
        fi

        if (( elapsed >= VERIFY_TIMEOUT )); then
            show_service_logs backend
            die "Backend health check failed. Expected {\"status\":\"healthy\"} from /health."
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
}

http_status() {
    local url="$1" method="${2:-GET}" body="${3:-}"
    if [[ "$method" == "POST" ]]; then
        curl -sS -o /dev/null -w '%{http_code}' --max-time 8 \
            -X POST -H 'Content-Type: application/json' -d "$body" "$url" 2>/dev/null || true
    else
        curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || true
    fi
}

local_url_host() {
    case "$BIND_ADDRESS" in
        0.0.0.0|127.0.0.1) printf 'localhost' ;;
        *) printf '%s' "$BIND_ADDRESS" ;;
    esac
}

wait_for_gateway_http() {
    local base_url="$1" elapsed=0 code

    log_info "Verifying gateway, frontend and API routing..."
    while :; do
        code=$(http_status "${base_url}/healthz")
        if [[ "$code" == "200" ]]; then
            break
        fi
        if (( elapsed >= 90 )); then
            show_service_logs gateway
            die "Gateway did not respond at ${base_url}/healthz (last status: ${code:-none})."
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    log_success "Gateway health endpoint responded."

    elapsed=0
    while :; do
        code=$(http_status "${base_url}/")
        case "$code" in
            200|301|302|303|307|308) break ;;
        esac
        if (( elapsed >= 90 )); then
            show_service_logs frontend
            die "Frontend did not respond through the gateway (last status: ${code:-none})."
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    log_success "Frontend is reachable."

    # A validation error (4xx) proves /api is proxied to FastAPI. A 404 or 502
    # means the request never reached the backend.
    elapsed=0
    while :; do
        code=$(http_status "${base_url}/api/v1/auth/login" POST '{}')
        if [[ "$code" =~ ^4[0-9][0-9]$ && "$code" != "404" ]]; then
            break
        fi
        if (( elapsed >= 90 )); then
            show_service_logs gateway
            show_service_logs backend
            die "API routing check failed: POST /api/v1/auth/login returned ${code:-none} (expected a 4xx validation response)."
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    log_success "API routing through the gateway is working."
}

# ------------------------------------------------------------------------------
# Final report
# ------------------------------------------------------------------------------
print_summary() {
    local host url compose_cmd
    host=$(local_url_host)
    url="http://${host}:${PORT}"
    compose_cmd="docker compose -p ${PROJECT} --env-file \"${ENV_FILE}\" -f \"${INSTALL_DIR}/docker-compose.yml\""

    cat <<EOF

${GREEN}${BOLD}SentinelForge is installed and running.${NC}

  Application URL : ${BOLD}${url}${NC}
  API base URL    : ${url}/api/v1
  Installer files : ${INSTALL_DIR}
  Configuration   : ${ENV_FILE} (mode 0600; secret values are not displayed)

  Services: frontend, backend, PostgreSQL, Redis and a local gateway proxy.
  PostgreSQL and Redis are internal-only and are not reachable from the host.

${BOLD}Next steps${NC}
  1. Open ${url} and register the first user.
  2. To grant an existing user admin access, see:
     docs/installation.md#create-or-promote-an-administrator
  3. Pin released image tags in ${ENV_FILE} for reproducible upgrades.

${BOLD}Common commands${NC}
  Status : ${compose_cmd} ps
  Logs   : ${compose_cmd} logs -f --tail=100
  Stop   : ${compose_cmd} stop
  Start  : ${compose_cmd} start
  Update : ${compose_cmd} pull && ${compose_cmd} --profile tools run --rm migrate && ${compose_cmd} up -d && ${compose_cmd} restart gateway

${BOLD}Data safety${NC}
  - Named volumes are preserved across installs and restarts.
  - Never edit POSTGRES_PASSWORD in ${ENV_FILE} after the first start; it will
    not match the initialized database.
  - Uninstall keeps data and configuration: scripts/uninstall.sh
  - Purging data requires explicit confirmation: scripts/uninstall.sh --purge-data

${BOLD}Troubleshooting${NC}
  - Full guide: docs/installation.md#troubleshooting
  - If a container is unhealthy: ${compose_cmd} logs --tail=100 <service>
  - If the port is busy: re-run with --port <free-port>
EOF
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    parse_args "$@"
    sanitize_compose_environment

    printf '%s%sSentinelForge Installer %s%s\n' "$BOLD" "$CYAN" "$INSTALLER_VERSION" "$NC"
    printf '%sSelf-hosted DevSecOps platform - Docker Compose deployment%s\n\n' "$BLUE" "$NC"

    log_step "1/8 Preflight checks"
    detect_platform
    check_prerequisites
    check_docker
    check_disk_space
    log_info "Platform: ${OS_FAMILY}; project: ${PROJECT}; port: ${PORT}"

    log_step "2/8 Preparing installation directory"
    prepare_install_dir
    acquire_lock

    log_step "3/8 Installing deployment configuration"
    prepare_assets
    install_assets

    log_step "4/8 Environment configuration"
    if [[ -f "$ENV_FILE" ]]; then
        load_existing_settings
        log_success "Existing configuration found; reusing it without changing secrets."
    else
        detect_existing_state
        write_env_file
        validate_env_file
    fi
    log_info "Configured images:"
    log_info "  backend  = $(env_value "$ENV_FILE" SENTINELFORGE_BACKEND_IMAGE)"
    log_info "  frontend = $(env_value "$ENV_FILE" SENTINELFORGE_FRONTEND_IMAGE)"
    log_info "  gateway  = $(env_value "$ENV_FILE" SENTINELFORGE_GATEWAY_IMAGE)"

    log_step "5/8 Validating configuration"
    validate_compose_config
    check_port_available

    log_step "6/8 Pulling images and starting data services"
    pull_images
    compose up -d postgres redis
    wait_for_health postgres 120
    wait_for_health redis 60

    log_step "7/8 Applying migrations and starting the application"
    run_migrations
    compose up -d --remove-orphans
    # Nginx resolves upstream service names at startup. Restart the gateway after
    # any backend/frontend recreation so it does not keep a stale container IP.
    compose restart gateway >/dev/null 2>&1 || true
    wait_for_health backend
    wait_for_health frontend
    wait_for_health gateway 90

    log_step "8/8 Verifying the installation"
    verify_backend_health
    wait_for_gateway_http "http://$(local_url_host):${PORT}"

    print_summary
    log_success "Installation completed successfully."
}

main "$@"
