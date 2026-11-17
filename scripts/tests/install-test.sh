#!/usr/bin/env bash
# ==============================================================================
# SentinelForge installer test suite
#
# Exercises scripts/install.sh and scripts/uninstall.sh without a Docker daemon
# by putting deterministic stubs (docker, curl, df, uname) on PATH.
#
# It never touches the real Docker daemon, existing volumes, Minikube, or the
# developer's installation directory. All state lives in a mktemp directory.
#
# Usage: bash scripts/tests/install-test.sh
# ==============================================================================

set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
INSTALL_SCRIPT="${ROOT_DIR}/scripts/install.sh"
UNINSTALL_SCRIPT="${ROOT_DIR}/scripts/uninstall.sh"

WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sentinelforge-tests.XXXXXX")
STUB_BIN="${WORK_ROOT}/bin"
PASS_COUNT=0
FAIL_COUNT=0
CURRENT_CASE=""

cleanup() {
    rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Test harness helpers
# ------------------------------------------------------------------------------
ok() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '  %sok%s   %s\n' $'\033[0;32m' $'\033[0m' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '  %sFAIL%s %s\n' $'\033[0;31m' $'\033[0m' "$1"
    if [[ -n "${LAST_OUTPUT:-}" ]]; then
        printf '       --- last output ---\n'
        printf '%s\n' "$LAST_OUTPUT" | sed 's/^/       /'
        printf '       -------------------\n'
    fi
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else fail "$label (expected '$expected', got '$actual')"; fi
}

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then ok "$label"; else fail "$label (missing: $needle)"; fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="$3"
    if [[ -z "$needle" ]]; then
        fail "$label (internal error: empty needle)"
    elif [[ "$haystack" != *"$needle"* ]]; then
        ok "$label"
    else
        fail "$label (secret or forbidden text was printed)"
    fi
}

assert_file() {
    local path="$1" label="$2"
    if [[ -f "$path" ]]; then ok "$label"; else fail "$label (missing $path)"; fi
}

assert_mode() {
    local path="$1" expected="$2" label="$3" actual
    actual=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || true)
    assert_eq "$expected" "$actual" "$label"
}

env_get() {
    awk -v key="$2" 'BEGIN { FS = "=" } $1 == key { sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit }' "$1"
}

begin_case() {
    CURRENT_CASE="$1"
    CASE_DIR="${WORK_ROOT}/${CURRENT_CASE}"
    export STUB_STATE="${CASE_DIR}/state"
    mkdir -p "$CASE_DIR/home" "$CASE_DIR/state" "$CASE_DIR/install"

    export STUB_DOCKER_RUNNING=1
    export STUB_COMPOSE_V1=0
    export STUB_DISK_KB=52428800
    export STUB_UNAME=Linux
    export STUB_VOLUME_EXISTS=0
    export STUB_VOLUME_NAMES=""
    export STUB_EXISTING_CONTAINERS=0
    export STUB_PORT_BOUND_BY_US=0
    export STUB_PULL_FAIL=0
    export STUB_MIGRATE_FAIL=0
    export STUB_MIGRATE_FAIL_LEAK=0
    export STUB_CONFIG_FAIL=0
    export STUB_HEALTH_FAIL=0
    export STUB_DOWNLOAD_FAIL=0
    export STUB_HTTP_FAIL=0

    LAST_OUTPUT=""
    LAST_STATUS=0
    printf '\n%s\n' "== ${CURRENT_CASE} =="
}

run_script() {
    local workdir="$1" script="$2"
    shift 2
    local out="${CASE_DIR}/output.log"

    set +e
    ( cd "$workdir" && env PATH="${STUB_BIN}:${PATH}" STUB_STATE="${STUB_STATE}" bash "$script" "$@" ) >"$out" 2>&1
    LAST_STATUS=$?
    set -e
    LAST_OUTPUT=$(cat "$out")
}

run_install() {
    run_script "$CASE_DIR" "$INSTALL_SCRIPT" --dir "${CASE_DIR}/install" --port "$PORT" "$@"
}

free_port() {
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
    else
        printf '18765'
    fi
}

docker_log() {
    cat "${STUB_STATE}/docker.log" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Stubs
# ------------------------------------------------------------------------------
write_stubs() {
    mkdir -p "$STUB_BIN"

    cat > "${STUB_BIN}/docker" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

log_file="${STUB_STATE:-/tmp}/docker.log"
printf '%s\n' "$*" >> "$log_file"

compose_subcommand() {
    local args=("$@") i=0 arg
    while (( i < ${#args[@]} )); do
        arg="${args[$i]}"
        case "$arg" in
            --project-directory|--env-file|--project-name|--profile|-f) i=$((i + 2)) ;;
            --project-directory=*|--env-file=*|--project-name=*|--profile=*) i=$((i + 1)) ;;
            -*) i=$((i + 1)) ;;
            *) printf '%s' "$arg"; return 0 ;;
        esac
    done
}

compose_env_file() {
    local args=("$@") i=0
    while (( i < ${#args[@]} )); do
        if [[ "${args[$i]}" == "--env-file" ]]; then
            printf '%s' "${args[$((i + 1))]}"
            return 0
        fi
        i=$((i + 1))
    done
}

case "${1:-}" in
    --version)
        echo "Docker version 27.0.0, build stub"
        ;;
    info)
        if [[ "${STUB_DOCKER_RUNNING:-1}" != "1" ]]; then
            echo "Cannot connect to the Docker daemon" >&2
            exit 1
        fi
        if [[ "${STUB_DOCKER_DESKTOP:-0}" == "1" && "$*" == *OperatingSystem* ]]; then
            echo "Docker Desktop"
            exit 0
        fi
        echo "27.0.0"
        ;;
    volume)
        # volume ls [--filter ...] [--format ...]
        if [[ "${2:-}" != "ls" ]]; then
            exit 0
        fi
        if [[ -n "${STUB_VOLUME_NAMES:-}" ]]; then
            printf '%s\n' "$STUB_VOLUME_NAMES"
        elif [[ "${STUB_VOLUME_EXISTS:-0}" == "1" ]]; then
            echo "${STUB_VOLUME_NAME:-sentinelforge_postgres_data}"
        fi
        ;;
    ps)
        if [[ "${STUB_EXISTING_CONTAINERS:-0}" == "1" ]]; then
            echo "sentinelforge-postgres"
        fi
        if [[ "${STUB_PORT_BOUND_BY_US:-0}" == "1" ]]; then
            echo "127.0.0.1:${STUB_BOUND_PORT:-8080}->8080/tcp"
        fi
        ;;
    inspect)
        if [[ "${STUB_HEALTHY:-1}" == "0" ]]; then
            echo "starting"
        else
            echo "healthy"
        fi
        ;;
    compose)
        shift
        if [[ "${1:-}" == "version" ]]; then
            if [[ "${STUB_COMPOSE_V1:-0}" == "1" ]]; then
                echo "docker-compose version 1.29.2, build unknown" >&2
                exit 1
            fi
            if [[ "${2:-}" == "--short" ]]; then
                echo "2.29.7"
            else
                echo "Docker Compose version v2.29.7"
            fi
            exit 0
        fi

        sub=$(compose_subcommand "$@")
        case "$sub" in
            config)
                if [[ "${STUB_CONFIG_FAIL:-0}" == "1" ]]; then
                    echo "invalid compose config" >&2
                    exit 1
                fi
                echo "name: stub"
                ;;
            pull)
                if [[ "${STUB_PULL_FAIL:-0}" == "1" ]]; then
                    echo "pull access denied" >&2
                    exit 1
                fi
                ;;
            up|start|stop|restart)
                ;;
            logs)
                echo "fatal: could not connect to database"
                env_file=$(compose_env_file "$@")
                if [[ -n "$env_file" && -f "$env_file" ]]; then
                    grep '^POSTGRES_PASSWORD=' "$env_file" | sed 's/^/env: /'
                fi
                echo "postgresql+asyncpg://sentinelforge:supersecret@postgres:5432/sentinelforge"
                ;;
            ps)
                # ps -q <service>
                for ((i = 1; i <= $#; i++)); do
                    if [[ "${!i}" == "-q" ]]; then
                        j=$((i + 1))
                        printf 'stub-%s\n' "${!j}"
                        exit 0
                    fi
                done
                echo "stub service table"
                ;;
            exec)
                if [[ "${STUB_HEALTH_FAIL:-0}" == "1" ]]; then
                    echo "degraded"
                else
                    echo "healthy"
                fi
                ;;
            run)
                if [[ "${STUB_MIGRATE_FAIL:-0}" == "1" ]]; then
                    if [[ "${STUB_MIGRATE_FAIL_LEAK:-0}" == "1" ]]; then
                        env_file=$(compose_env_file "$@")
                        if [[ -n "$env_file" && -f "$env_file" ]]; then
                            echo "connection failed: $(grep '^POSTGRES_PASSWORD=' "$env_file")"
                        fi
                    fi
                    echo "alembic upgrade failed: boom" >&2
                    exit 1
                fi
                ;;
            down)
                ;;
            *)
                ;;
        esac
        ;;
    *)
        ;;
esac

exit 0
STUB

    cat > "${STUB_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

out_file=""
url=""
want_code=0
prev=""
for arg in "$@"; do
    case "$arg" in
        -o) : ;;
        -w) want_code=1 ;;
    esac
    if [[ "$prev" == "-o" ]]; then
        out_file="$arg"
    fi
    case "$arg" in
        http://*|https://*) url="$arg" ;; # NOSONAR test stub parses both schemes
    esac
    prev="$arg"
done

if [[ "$url" == *"raw.githubusercontent.com"* ]]; then
    if [[ "${STUB_DOWNLOAD_FAIL:-0}" == "1" ]]; then
        echo "curl: (22) 404" >&2
        exit 22
    fi
    if [[ -n "$out_file" && "$out_file" != "/dev/null" ]]; then
        mkdir -p "$(dirname "$out_file")"
        case "$url" in
            *docker-compose.yml) printf 'services:\n  stub:\n    image: stub\n' > "$out_file" ;;
            *.env.example) printf 'POSTGRES_PASSWORD=placeholder\n' > "$out_file" ;;
            *nginx.conf) printf 'server { listen 8080; }\n' > "$out_file" ;;
            *) printf 'stub\n' > "$out_file" ;;
        esac
    fi
    exit 0
fi

if (( want_code == 1 )); then
    if [[ "${STUB_HTTP_FAIL:-0}" == "1" ]]; then
        printf '000'
    elif [[ "$url" == *"/api/"* ]]; then
        printf '422'
    else
        printf '200'
    fi
fi
exit 0
STUB

    cat > "${STUB_BIN}/df" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'stubfs %s 0 %s 1%% /\n' "$(( ${STUB_DISK_KB:-52428800} + 1024 ))" "${STUB_DISK_KB:-52428800}"
STUB

    cat > "${STUB_BIN}/uname" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
    -m) echo "x86_64" ;;
    *) echo "${STUB_UNAME:-Linux}" ;;
esac
STUB

    chmod +x "${STUB_BIN}/docker" "${STUB_BIN}/curl" "${STUB_BIN}/df" "${STUB_BIN}/uname"
}

# ------------------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------------------
test_syntax_and_help() {
    begin_case "syntax-and-help"
    if bash -n "$INSTALL_SCRIPT" && bash -n "$UNINSTALL_SCRIPT"; then
        ok "bash -n passes for install.sh and uninstall.sh"
    else
        fail "bash -n failed"
    fi

    run_script "$CASE_DIR" "$INSTALL_SCRIPT" --help
    assert_eq "0" "$LAST_STATUS" "--help exits 0"
    assert_contains "$LAST_OUTPUT" "Usage:" "--help prints usage"

    run_script "$CASE_DIR" "$INSTALL_SCRIPT" --version
    assert_contains "$LAST_OUTPUT" "installer 1.0.0" "--version prints installer version"

    run_script "$CASE_DIR" "$UNINSTALL_SCRIPT" --help
    assert_eq "0" "$LAST_STATUS" "uninstall --help exits 0"
    assert_contains "$LAST_OUTPUT" "Data safety:" "uninstall --help documents data safety"

    run_script "$CASE_DIR" "$UNINSTALL_SCRIPT" --version
    assert_contains "$LAST_OUTPUT" "uninstaller 1.0.0" "uninstall --version prints uninstaller version"
}

test_platform_detection() {
    begin_case "unsupported-windows-shell"
    export STUB_UNAME="MINGW64_NT-10.0-22631"
    run_install
    if (( LAST_STATUS != 0 )); then ok "rejects Windows shells"; else fail "should reject Windows shell"; fi
    assert_contains "$LAST_OUTPUT" "WSL2" "explains WSL2 alternative"
}

test_docker_checks() {
    begin_case "docker-missing"
    local nodocker_path="/usr/bin:/bin"
    set +e
    env -i PATH="$nodocker_path" HOME="$CASE_DIR/home" TMPDIR="${TMPDIR:-/tmp}" \
        "$INSTALL_SCRIPT" --dir "${CASE_DIR}/install" >"${CASE_DIR}/missing.log" 2>&1
    local status=$?
    set -e
    LAST_OUTPUT=$(cat "${CASE_DIR}/missing.log")
    if PATH="$nodocker_path" command -v docker >/dev/null 2>&1; then
        ok "skipped docker-missing (docker is available in /usr/bin)"
    elif (( status != 0 )); then
        ok "fails when docker is missing"
        assert_contains "$LAST_OUTPUT" "Docker is not installed" "reports missing Docker"
    else
        fail "should fail when docker is missing"
    fi

    begin_case "daemon-down"
    export STUB_DOCKER_RUNNING=0
    run_install
    if (( LAST_STATUS != 0 )); then ok "fails when the daemon is down"; else fail "should fail when daemon is down"; fi
    assert_contains "$LAST_OUTPUT" "daemon is not running" "reports daemon not running"

    begin_case "compose-v1"
    export STUB_COMPOSE_V1=1
    run_install
    if (( LAST_STATUS != 0 )); then ok "rejects Docker Compose v1"; else fail "should reject Compose v1"; fi
    assert_contains "$LAST_OUTPUT" "Compose v2" "explains Compose v2 requirement"
}

test_disk_and_port_checks() {
    begin_case "low-disk"
    export STUB_DISK_KB=1048576
    run_install
    if (( LAST_STATUS != 0 )); then ok "rejects insufficient disk space"; else fail "should reject low disk space"; fi
    assert_contains "$LAST_OUTPUT" "Not enough disk space" "reports disk requirement"

    begin_case "wsl-docker-desktop-disk"
    export STUB_DISK_KB=1048576
    export WSL_DISTRO_NAME="Ubuntu"
    export STUB_DOCKER_DESKTOP=1
    PORT=$(free_port)
    export PORT
    run_install
    assert_eq "0" "$LAST_STATUS" "WSL2 with Docker Desktop is not blocked by WSL free space"
    assert_not_contains "$LAST_OUTPUT" "Not enough disk space" "does not fail the WSL disk check"
    unset WSL_DISTRO_NAME
    unset STUB_DOCKER_DESKTOP

    begin_case "invalid-port"
    run_script "$CASE_DIR" "$INSTALL_SCRIPT" --dir "${CASE_DIR}/install" --port 70000
    assert_eq "2" "$LAST_STATUS" "invalid port is a usage error"
    assert_contains "$LAST_OUTPUT" "Invalid --port" "reports invalid port"

    begin_case "invalid-bind"
    run_script "$CASE_DIR" "$INSTALL_SCRIPT" --dir "${CASE_DIR}/install" --bind not-an-ip
    assert_eq "2" "$LAST_STATUS" "invalid bind is a usage error"

    begin_case "invalid-bind-octet"
    run_script "$CASE_DIR" "$INSTALL_SCRIPT" --dir "${CASE_DIR}/install" --bind 999.999.999.999
    assert_eq "2" "$LAST_STATUS" "out-of-range bind is a usage error"

    begin_case "invalid-project"
    run_script "$CASE_DIR" "$INSTALL_SCRIPT" --dir "${CASE_DIR}/install" --project-name "Bad Name"
    assert_eq "2" "$LAST_STATUS" "invalid project name is a usage error"
}

test_fresh_install() {
    begin_case "fresh-install"
    PORT=$(free_port)
    export PORT
    run_install

    assert_eq "0" "$LAST_STATUS" "fresh install exits 0"
    assert_contains "$LAST_OUTPUT" "Installation completed successfully" "reports success"
    assert_contains "$LAST_OUTPUT" "http://localhost:${PORT}" "prints the application URL" # NOSONAR test assertion

    local env_file="${CASE_DIR}/install/.env"
    assert_file "$env_file" "creates .env"
    assert_mode "${CASE_DIR}/install" "700" "installation directory is 0700"
    assert_mode "$env_file" "600" ".env is 0600"
    assert_file "${CASE_DIR}/install/docker-compose.yml" "installs docker-compose.yml"
    assert_file "${CASE_DIR}/install/config/nginx.conf" "installs gateway config"
    assert_file "${CASE_DIR}/install/.installer-version" "records installer version"

    local password jwt
    password=$(env_get "$env_file" POSTGRES_PASSWORD)
    jwt=$(env_get "$env_file" JWT_SECRET_KEY)
    [[ "$password" =~ ^[0-9a-f]{64}$ ]] && ok "database password is 32 random bytes (hex)" || fail "database password is not 64 hex characters"
    [[ "$jwt" =~ ^[0-9a-f]{64}$ ]] && ok "JWT secret is 32 random bytes (hex)" || fail "JWT secret is not 64 hex characters"
    if [[ "$password" != "$jwt" ]]; then ok "secrets are independently generated"; else fail "secrets are identical"; fi
    assert_not_contains "$LAST_OUTPUT" "$password" "database password is never printed"
    assert_not_contains "$LAST_OUTPUT" "$jwt" "JWT secret is never printed"

    local log
    log=$(docker_log)
    assert_contains "$log" "pull --quiet postgres redis backend frontend gateway" "pulls images"
    assert_contains "$log" "up -d postgres redis" "starts data services first"
    assert_contains "$log" "--profile tools run --rm --no-deps -T migrate" "runs Alembic migrations"
    assert_contains "$log" "up -d --remove-orphans" "starts the full stack"
    assert_contains "$log" "restart gateway" "refreshes gateway DNS after stack start"
    assert_not_contains "$log" "-p 5432" "does not publish PostgreSQL"
}

test_skip_pull() {
    begin_case "skip-pull"
    PORT=$(free_port)
    export PORT
    run_install --skip-pull
    assert_eq "0" "$LAST_STATUS" "--skip-pull install succeeds"
    assert_contains "$LAST_OUTPUT" "Skipping image pull" "warns that images were not pulled"
    assert_not_contains "$(docker_log)" "pull --quiet" "does not call compose pull"
}

test_idempotency_and_tag_update() {    begin_case "idempotency"
    PORT=$(free_port)
    export PORT
    run_install
    assert_eq "0" "$LAST_STATUS" "first install succeeds"

    local env_file="${CASE_DIR}/install/.env" before after
    before=$(cat "$env_file")
    sleep 1
    run_install
    assert_eq "0" "$LAST_STATUS" "second install exits 0"
    assert_contains "$LAST_OUTPUT" "reusing it without changing secrets" "reuses existing configuration"
    after=$(cat "$env_file")
    assert_eq "$before" "$after" ".env is byte-for-byte unchanged"
    assert_mode "$env_file" "600" ".env permissions stay 0600"

    local password_before
    password_before=$(env_get "$env_file" POSTGRES_PASSWORD)
    run_install --tag 9.9.9
    assert_eq "0" "$LAST_STATUS" "install with --tag succeeds"
    assert_eq "joypatel2403/sentinelforge-backend:9.9.9" "$(env_get "$env_file" SENTINELFORGE_BACKEND_IMAGE)" "updates backend image tag"
    assert_eq "$password_before" "$(env_get "$env_file" POSTGRES_PASSWORD)" "--tag does not touch secrets"

    run_install --project-name other-project
    if (( LAST_STATUS != 0 )); then ok "refuses to change the project name"; else fail "should refuse project rename"; fi
    assert_contains "$LAST_OUTPUT" "orphan" "explains why project rename is refused"
}

test_existing_state_protection() {
    begin_case "existing-volume-without-env"
    STUB_VOLUME_EXISTS=1
    export STUB_VOLUME_EXISTS
    run_install
    if (( LAST_STATUS != 0 )); then ok "refuses to regenerate secrets for existing data"; else fail "should refuse existing volume without .env"; fi
    assert_contains "$LAST_OUTPUT" "Refusing to generate new credentials" "explains the credential risk"
    if [[ ! -f "${CASE_DIR}/install/.env" ]]; then ok "does not create .env"; else fail "created .env for existing data"; fi

    begin_case "existing-containers-without-env"
    STUB_EXISTING_CONTAINERS=1
    export STUB_EXISTING_CONTAINERS
    run_install
    if (( LAST_STATUS != 0 )); then ok "refuses when existing containers are present"; else fail "should refuse existing containers"; fi
}

test_configuration_errors() {
    begin_case "invalid-existing-config"
    PORT=$(free_port)
    export PORT
    run_install
    assert_eq "0" "$LAST_STATUS" "baseline install succeeds"

    local env_file="${CASE_DIR}/install/.env"
    sed -i 's/^JWT_SECRET_KEY=.*/JWT_SECRET_KEY=replace_with_openssl_rand_hex_32/' "$env_file"
    chmod 600 "$env_file"
    local before
    before=$(cat "$env_file")
    run_install
    if (( LAST_STATUS != 0 )); then ok "rejects placeholder secrets in existing config"; else fail "should reject placeholder JWT"; fi
    assert_contains "$LAST_OUTPUT" "placeholder" "reports the placeholder"
    assert_eq "$before" "$(cat "$env_file")" "does not rewrite an invalid existing .env"

    begin_case "compose-config-failure"
    PORT=$(free_port)
    export PORT
    export STUB_CONFIG_FAIL=1
    run_install
    if (( LAST_STATUS != 0 )); then ok "fails on invalid Compose configuration"; else fail "should fail on invalid compose config"; fi
    assert_contains "$LAST_OUTPUT" "configuration is invalid" "reports invalid configuration"

    begin_case "pull-failure"
    PORT=$(free_port)
    export PORT
    export STUB_PULL_FAIL=1
    run_install
    if (( LAST_STATUS != 0 )); then ok "fails when images cannot be pulled"; else fail "should fail on pull error"; fi
    assert_contains "$LAST_OUTPUT" "Unable to pull images" "reports pull failure"
}

test_migrations() {
    begin_case "migration-failure"
    PORT=$(free_port)
    export PORT
    export STUB_MIGRATE_FAIL=1
    run_install
    if (( LAST_STATUS != 0 )); then ok "fails when migrations fail"; else fail "should fail on migration error"; fi
    assert_contains "$LAST_OUTPUT" "Database migration failed" "reports migration failure"
    assert_mode "${CASE_DIR}/install/.env" "600" ".env survives a failed migration"

    begin_case "migration-output-secret-suppression"
    PORT=$(free_port)
    export PORT
    export STUB_MIGRATE_FAIL=1
    export STUB_MIGRATE_FAIL_LEAK=1
    run_install
    if (( LAST_STATUS != 0 )); then ok "fails on a leaking migration error"; else fail "should fail"; fi
    local password
    password=$(env_get "${CASE_DIR}/install/.env" POSTGRES_PASSWORD)
    assert_not_contains "$LAST_OUTPUT" "$password" "suppresses credentials in migration output"
    assert_contains "$LAST_OUTPUT" "suppressed" "explains that output was suppressed"

    begin_case "skip-migrations"
    PORT=$(free_port)
    export PORT
    run_install --skip-migrations
    assert_eq "0" "$LAST_STATUS" "--skip-migrations install succeeds"
    assert_not_contains "$(docker_log)" "--profile tools run" "does not run migrations when skipped"
    assert_contains "$LAST_OUTPUT" "Skipping database migrations" "warns about skipped migrations"
}

test_health_failure() {
    begin_case "backend-unhealthy"
    PORT=$(free_port)
    export PORT
    export STUB_HEALTH_FAIL=1
    export SENTINELFORGE_VERIFY_TIMEOUT=1
    run_install
    if (( LAST_STATUS != 0 )); then ok "fails when the backend is unhealthy"; else fail "should fail when backend is unhealthy"; fi
    assert_contains "$LAST_OUTPUT" "Backend health check failed" "reports backend health failure"

    local password
    password=$(env_get "${CASE_DIR}/install/.env" POSTGRES_PASSWORD)
    assert_not_contains "$LAST_OUTPUT" "$password" "redacts the database password in service logs"
    assert_not_contains "$LAST_OUTPUT" "supersecret" "redacts credentials in connection strings"
    assert_contains "$LAST_OUTPUT" "[REDACTED]" "marks redacted log content"
    unset SENTINELFORGE_VERIFY_TIMEOUT
}

test_remote_asset_mode() {
    begin_case "remote-assets"
    mkdir -p "${CASE_DIR}/solo/scripts"
    cp "$INSTALL_SCRIPT" "${CASE_DIR}/solo/scripts/install.sh"
    PORT=$(free_port)
    run_script "$CASE_DIR" "${CASE_DIR}/solo/scripts/install.sh" \
        --dir "${CASE_DIR}/install" --port "$PORT"

    assert_eq "0" "$LAST_STATUS" "downloads assets when no local checkout is available"
    assert_contains "$LAST_OUTPUT" "Downloading docker-compose.yml" "downloads the Compose file"
    assert_file "${CASE_DIR}/install/docker-compose.yml" "installs downloaded Compose file"

    begin_case "remote-assets-failure"
    mkdir -p "${CASE_DIR}/solo/scripts"
    cp "$INSTALL_SCRIPT" "${CASE_DIR}/solo/scripts/install.sh"
    export STUB_DOWNLOAD_FAIL=1
    run_script "$CASE_DIR" "${CASE_DIR}/solo/scripts/install.sh" --dir "${CASE_DIR}/install"
    if (( LAST_STATUS != 0 )); then ok "fails when assets cannot be downloaded"; else fail "should fail without assets"; fi
    assert_contains "$LAST_OUTPUT" "Unable to obtain deployment assets" "reports asset download failure"
}

test_uninstall() {
    begin_case "uninstall-dry-run"
    PORT=$(free_port)
    export PORT
    run_install
    run_script "$CASE_DIR" "$UNINSTALL_SCRIPT" --dir "${CASE_DIR}/install" --dry-run
    assert_eq "0" "$LAST_STATUS" "uninstall --dry-run exits 0"
    assert_contains "$LAST_OUTPUT" "Nothing was changed" "dry run reports no changes"
    assert_not_contains "$(docker_log)" "down --remove-orphans" "dry run does not remove containers"

    begin_case "uninstall-preserves-data"
    PORT=$(free_port)
    export PORT
    run_install
    assert_eq "0" "$LAST_STATUS" "baseline install succeeds"
    run_script "$CASE_DIR" "$UNINSTALL_SCRIPT" --dir "${CASE_DIR}/install" --yes
    assert_eq "0" "$LAST_STATUS" "uninstall --yes exits 0"
    local log
    log=$(docker_log)
    assert_contains "$log" "down --remove-orphans" "removes containers and network"
    assert_not_contains "$log" "down --volumes" "does not delete volumes"
    assert_file "${CASE_DIR}/install/.env" "preserves the configuration file"
    assert_contains "$LAST_OUTPUT" "Persistent volumes were preserved" "confirms data preservation"

    begin_case "uninstall-purge-dry-run"
    PORT=$(free_port)
    export PORT
    run_install
    run_script "$CASE_DIR" "$UNINSTALL_SCRIPT" --dir "${CASE_DIR}/install" --purge-data --dry-run
    assert_eq "0" "$LAST_STATUS" "purge dry run exits 0"
    assert_contains "$LAST_OUTPUT" "PURGE MODE" "warns before destructive purge"
    assert_contains "$LAST_OUTPUT" "would additionally run" "describes destructive action"
    assert_not_contains "$(docker_log)" "--volumes" "does not delete volumes in dry run"

    begin_case "uninstall-requires-config"
    run_script "$CASE_DIR" "$UNINSTALL_SCRIPT" --dir "${CASE_DIR}/install" --yes
    if (( LAST_STATUS != 0 )); then ok "refuses to uninstall without configuration"; else fail "should require .env"; fi
}

# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------
main() {
    write_stubs

    PORT=$(free_port)
    export PORT

    printf 'SentinelForge installer test suite\n'
    printf 'Work directory: %s\n' "$WORK_ROOT"

    test_syntax_and_help
    test_platform_detection
    test_docker_checks
    test_disk_and_port_checks
    test_fresh_install
    test_skip_pull
    test_idempotency_and_tag_update
    test_existing_state_protection
    test_configuration_errors
    test_migrations
    test_health_failure
    test_remote_asset_mode
    test_uninstall

    printf '\n%s\n' "----------------------------------------"
    printf 'Passed: %s   Failed: %s\n' "$PASS_COUNT" "$FAIL_COUNT"

    if (( FAIL_COUNT > 0 )); then
        exit 1
    fi
}

main "$@"
