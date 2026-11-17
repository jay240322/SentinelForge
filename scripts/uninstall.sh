#!/usr/bin/env bash
# ==============================================================================
# SentinelForge - Safe Docker Compose Uninstaller
#
# By default this script ONLY stops and removes containers and the Compose
# network. It never deletes PostgreSQL data, Redis data, user accounts, audit
# logs, security alerts or the generated configuration file.
#
# Deleting persistent data requires BOTH --purge-data and an interactive
# confirmation phrase. This script never touches Kubernetes resources or PVCs.
# ==============================================================================

set -Eeuo pipefail
umask 077
set +x

readonly SCRIPT_VERSION="1.0.0"
readonly DEFAULT_PROJECT="sentinelforge"

INSTALL_DIR="${SENTINELFORGE_HOME:-${HOME:-/tmp}/.sentinelforge}"
PROJECT="${SENTINELFORGE_PROJECT:-$DEFAULT_PROJECT}"
PROJECT_SET=false
PURGE_DATA=false
ASSUME_YES=false
DRY_RUN=false
ENV_FILE=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    BOLD=""
    NC=""
fi

log_info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
log_success() { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
log_warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_error() { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*" >&2; }

die() {
    log_error "$*"
    exit 1
}

die_usage() {
    log_error "$*"
    printf 'Run "%s --help" for usage.\n' "${0##*/}" >&2
    exit 2
}

usage() {
    cat <<'EOF'
SentinelForge Docker Compose uninstaller

Usage:
  ./scripts/uninstall.sh [options]

Options:
  --dir PATH            Installation directory (default: ~/.sentinelforge)
  --project-name NAME   Docker Compose project name (default: from .env)
  --purge-data          ALSO delete PostgreSQL/Redis volumes. Requires an
                        interactive confirmation phrase. Data is unrecoverable.
  --yes                 Skip the non-destructive uninstall confirmation.
                        Does NOT bypass the --purge-data confirmation.
  --dry-run             Show what would happen without changing anything
  -h, --help            Show this help
  --version             Show uninstaller version

Data safety:
  * Default mode preserves all named volumes and the configuration file.
  * --purge-data removes Docker volumes only. The installation directory and
    .env file are always preserved; remove them manually if desired.
  * Kubernetes resources, persistent volume claims (PVCs) and Minikube data
    are never modified by this script.
EOF
}

env_value() {
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

parse_args() {
    local tilde='~'

    [[ -n "${SENTINELFORGE_PROJECT:-}" ]] && PROJECT_SET=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir)
                [[ $# -ge 2 && -n "$2" ]] || die_usage "--dir requires a path"
                INSTALL_DIR="$2"
                shift 2
                ;;
            --dir=*)
                INSTALL_DIR="${1#*=}"
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
            --purge-data)
                PURGE_DATA=true
                shift
                ;;
            --yes|-y)
                ASSUME_YES=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --version)
                printf 'SentinelForge uninstaller %s\n' "$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                die_usage "Unknown option: $1"
                ;;
        esac
    done

    case "$INSTALL_DIR" in
        "$tilde") INSTALL_DIR="$HOME" ;;
        "$tilde/"*) INSTALL_DIR="${HOME}/${INSTALL_DIR#"$tilde/"}" ;;
    esac
    case "$INSTALL_DIR" in
        /*) ;;
        *) INSTALL_DIR="$(pwd -P)/${INSTALL_DIR}" ;;
    esac

    [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
        || die_usage "Invalid project name. Use lowercase letters, digits, '-' or '_'."
}

compose() {
    # Keep the validated .env authoritative over ambient shell variables.
    unset POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB \
        JWT_SECRET_KEY JWT_ALGORITHM \
        ACCESS_TOKEN_EXPIRE_MINUTES REFRESH_TOKEN_EXPIRE_DAYS \
        SENTINELFORGE_BACKEND_IMAGE SENTINELFORGE_FRONTEND_IMAGE \
        SENTINELFORGE_GATEWAY_IMAGE SENTINELFORGE_PORT SENTINELFORGE_BIND \
        COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_PROFILES COMPOSE_ENV_FILES

    docker compose \
        --project-directory "$INSTALL_DIR" \
        --env-file "$ENV_FILE" \
        --project-name "$PROJECT" \
        -f "${INSTALL_DIR}/docker-compose.yml" \
        "$@"
}

confirm_phrase() {
    local prompt="$1" expected="$2" answer=""

    if [[ ! -r /dev/tty ]]; then
        log_error "Interactive confirmation is required but no terminal is available."
        return 1
    fi

    printf '%s' "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty || return 1
    [[ "$answer" == "$expected" ]]
}

main() {
    parse_args "$@"

    command -v docker >/dev/null 2>&1 \
        || die "Docker is not installed or not on PATH."

    [[ -d "$INSTALL_DIR" ]] \
        || die "Installation directory not found: ${INSTALL_DIR}"

    ENV_FILE="${INSTALL_DIR}/.env"
    [[ -f "$ENV_FILE" ]] \
        || die "Environment file not found: ${ENV_FILE}. Refusing to guess credentials or project settings."

    [[ -f "${INSTALL_DIR}/docker-compose.yml" ]] \
        || die "Compose file not found: ${INSTALL_DIR}/docker-compose.yml"

    local configured_password configured_jwt
    configured_password=$(env_value "$ENV_FILE" POSTGRES_PASSWORD)
    configured_jwt=$(env_value "$ENV_FILE" JWT_SECRET_KEY)
    if [[ -z "$configured_password" || -z "$configured_jwt" ]]; then
        die "Environment file is incomplete (missing required keys). Restore the original .env or remove the stack manually with Docker Compose."
    fi

    if [[ "$PROJECT_SET" != "true" ]]; then
        local stored_project
        stored_project=$(env_value "$ENV_FILE" COMPOSE_PROJECT_NAME)
        [[ -n "$stored_project" ]] || die "COMPOSE_PROJECT_NAME is missing from ${ENV_FILE}."
        PROJECT="$stored_project"
    fi
    [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
        || die "Invalid project name in configuration."

    log_info "Installation: ${INSTALL_DIR}"
    log_info "Compose project: ${PROJECT}"

    if ! docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
        die "The Docker daemon is not running or not reachable."
    fi

    local volumes
    volumes=$(docker volume ls --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Name}}' 2>/dev/null || true)

    if [[ "$PURGE_DATA" == "true" ]]; then
        log_warn "PURGE MODE: PostgreSQL and Redis data volumes will be DELETED."
        log_warn "PostgreSQL data, user accounts, audit logs and security alerts are unrecoverable."
        log_warn "Create a database backup first: see docs/installation.md#backup-and-restore"
        if [[ -n "$volumes" ]]; then
            log_warn "Volumes selected for deletion:"
            printf '%s\n' "$volumes" >&2
        else
            log_warn "No project-labelled volumes were found; only containers and the network will be removed."
        fi
    else
        log_info "Data volumes will be preserved. Use --purge-data only if you intend to destroy all data."
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry run: would run 'docker compose ... down --remove-orphans'"
        [[ "$PURGE_DATA" == "true" ]] && log_info "Dry run: would additionally run 'docker compose ... down --volumes'"
        log_info "Dry run complete. Nothing was changed."
        return 0
    fi

    if [[ "$ASSUME_YES" != "true" ]]; then
        if ! confirm_phrase \
            "Type 'uninstall' to remove SentinelForge containers and network: " \
            "uninstall"; then
            die "Uninstall cancelled. Nothing was changed."
        fi
    fi

    log_info "Stopping and removing containers and the Compose network..."
    compose down --remove-orphans

    if [[ "$PURGE_DATA" == "true" ]]; then
        if ! confirm_phrase \
            "This permanently deletes PostgreSQL/Redis volumes. Type 'DELETE DATA' to continue: " \
            "DELETE DATA"; then
            log_warn "Data purge cancelled. Containers are stopped; volumes were NOT deleted."
            exit 1
        fi
        log_info "Deleting persistent Docker volumes..."
        compose down --volumes --remove-orphans
        log_success "Containers, network and persistent Docker volumes were removed."
    else
        log_success "Containers and network removed. Persistent volumes were preserved."
    fi

    cat <<EOF

${GREEN}${BOLD}Uninstall complete.${NC}

  Preserved:
    - PostgreSQL and Redis Docker volumes (unless --purge-data was used)
    - Configuration directory: ${INSTALL_DIR}
    - Environment file:        ${ENV_FILE} (mode 0600)
    - Kubernetes resources and PVCs (never touched by this script)

  To reinstall using the same data and configuration:
    ./scripts/install.sh --dir "${INSTALL_DIR}"

  To remove the configuration after taking a secure backup:
    rm -rf "${INSTALL_DIR}"

  Kubernetes deployments are managed separately with kubectl/Argo CD.
EOF
}

main "$@"
