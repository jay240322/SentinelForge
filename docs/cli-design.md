# `sentinelforge` CLI Design (Planned)

This document specifies the lifecycle CLI that will wrap the Docker Compose
installation. **It is design-only in this branch.** No global `sentinelforge`
command is installed yet.

The goal is a small, predictable operator interface that reuses the installer,
the uninstaller and Docker Compose instead of reimplementing deployment logic.

---

## Scope

The CLI manages a single self-hosted Docker Compose installation:

```text
sentinelforge <command> [options]
```

| Command | Purpose |
| :--- | :--- |
| `install` | Install or reconcile the stack (delegates to `scripts/install.sh`) |
| `start` | Start stopped containers and wait for health |
| `stop` | Stop containers without removing them or their data |
| `restart` | Restart containers |
| `status` | Show container state, health, URLs and version |
| `logs [service]` | Stream or tail service logs |
| `update` | Pull newer images, migrate, restart and verify |
| `backup` | Create a PostgreSQL dump and configuration archive |
| `restore` | Restore a dump with explicit confirmation |
| `uninstall` | Remove containers/network, preserving data by default |
| `version` | Print CLI and installed component versions |
| `doctor` | Run preflight/diagnostic checks |

Commands that change data (`restore`, `uninstall --purge-data`) require explicit
confirmation. Commands never print secrets.

---

## Location and discovery

- Binary/launcher: `~/.local/bin/sentinelforge` (overridable with
  `SENTINELFORGE_BIN_DIR`).
- Installation directory: `~/.sentinelforge` (overridable with
  `SENTINELFORGE_HOME`).
- Configuration: `~/.sentinelforge/.env`.
- Compose file: `~/.sentinelforge/docker-compose.yml`.
- Project name: `COMPOSE_PROJECT_NAME` from `.env`, default `sentinelforge`.
- Downloadable installer: `scripts/install.sh` from the official repository.

The CLI refuses to guess when configuration is missing. If `~/.sentinelforge`
does not exist, it reports that SentinelForge is not installed and suggests
`sentinelforge install` or `scripts/install.sh`.

---

## Command behaviour

### `sentinelforge install`

Delegates to the audited installer rather than duplicating logic:

```text
sentinelforge install [--port N] [--bind ADDR] [--tag TAG] [--dir PATH]
```

- Runs the same preflight checks, secret generation, asset installation,
  migration and verification steps as `scripts/install.sh`.
- Idempotent: reuses `.env` and volumes.
- Refuses to regenerate secrets when data exists without configuration.
- Exit codes mirror the installer (`0` success, `1` failure, `2` usage error).

### `sentinelforge start`

```text
sentinelforge start [--timeout SECONDS]
```

1. Load and validate `.env` (presence, permissions, required keys; no secret
   printing).
2. `docker compose up -d --remove-orphans` to converge the declared state.
3. Wait for `postgres`, `redis`, `backend`, `frontend` and `gateway` health.
4. Verify `http://127.0.0.1:<port>/healthz` and `/api/v1/auth/login` routing.
5. Print the application URL.

Does not run migrations; use `install` or `update` for schema changes.

### `sentinelforge stop`

```text
sentinelforge stop [--timeout SECONDS]
```

- `docker compose stop` (containers and volumes are kept).
- Never deletes volumes, configuration or logs.
- Safe to run repeatedly.

### `sentinelforge restart`

```text
sentinelforge restart [service ...]
```

- `docker compose restart` for the selected services, or all services.
- Re-runs health verification unless `--no-wait` is supplied.

### `sentinelforge status`

```text
sentinelforge status [--json]
```

Human-readable output:

```text
SentinelForge
  Installation : /home/user/.sentinelforge
  Project      : sentinelforge
  CLI version  : 1.0.0
  Images       : backend=...:v1.0.0 frontend=...:v1.0.0

  SERVICE    STATE     HEALTH    PORTS
  gateway    running   healthy   127.0.0.1:8080->8080
  frontend   running   healthy   -
  backend    running   healthy   -
  postgres   running   healthy   -
  redis      running   healthy   -

  URL          : http://localhost:8080
  Data volumes : preserved
```

- `--json` emits a stable machine-readable object for monitoring.
- Secret values are never included.
- Exit code is non-zero if any required service is not healthy.

### `sentinelforge logs`

```text
sentinelforge logs [service] [--tail N] [--since DURATION] [--no-follow]
```

- Default: all services, `--tail=100`, follow enabled.
- `service` is one of `gateway`, `frontend`, `backend`, `postgres`, `redis`,
  `migrate`, or omitted for all.
- Passes through Compose log options; does not dump `.env`.
- Warns that logs may contain personal data.

### `sentinelforge update`

```text
sentinelforge update [--tag TAG] [--check] [--yes]
```

1. Resolve the target tags (explicit `--tag`, or the configured tags with a
   pull).
2. With `--check`, report whether newer images are available and exit without
   changing anything.
3. Warn that a backup is recommended and, unless `--yes`, require confirmation.
4. `docker compose pull`.
5. Run `docker compose --profile tools run --rm migrate`.
6. `docker compose up -d --remove-orphans`.
7. Wait for health and verify routing.
8. On failure: keep the previous images available, print the failing service
   logs, and explain rollback. Never delete volumes.

Database migrations are forward-only. The CLI must state that a rollback after
an incompatible migration requires restoring a backup.

### `sentinelforge backup`

```text
sentinelforge backup [--dir PATH]
```

- Creates a custom-format `pg_dump` and a configuration archive with `umask 077`.
- Output files are mode `0600`.
- Prints file paths but not contents.
- Fails if the database is not healthy.

### `sentinelforge restore`

```text
sentinelforge restore <dump> [--yes]
```

1. Warns that the operation overwrites schema and data.
2. Requires typed confirmation (`RESTORE DATA`) unless `--yes` is supplied for
   automation, and requires a fresh safety backup first.
3. Stops application containers, runs `pg_restore --clean --if-exists`, then
   restarts and verifies.
4. Never deletes volumes.

### `sentinelforge uninstall`

```text
sentinelforge uninstall [--purge-data] [--yes]
```

- Default: remove containers and network only; preserve volumes and `.env`.
- `--purge-data`: additionally remove named volumes after a separate typed
  confirmation (`DELETE DATA`).
- Delegates to `scripts/uninstall.sh` so behaviour stays identical.
- Never affects Kubernetes resources or PVCs.

### `sentinelforge doctor`

```text
sentinelforge doctor
```

Checks and reports, without changing anything:

- Docker CLI, Compose v2 and daemon reachability
- Free disk space
- Installation directory and `.env` permissions
- Required environment keys and placeholder detection
- Port availability/ownership
- Container health and gateway routing
- Whether the backend image contains Alembic files

Exit code `0` if all checks pass, `1` otherwise.

### `sentinelforge version`

Prints the CLI version, installer version marker
(`~/.sentinelforge/.installer-version`), image references and Compose project.
Never prints secrets.

---

## Global options

| Option | Behaviour |
| :--- | :--- |
| `--dir PATH` | Installation directory (default `~/.sentinelforge`) |
| `--project-name NAME` | Compose project override; changing it after install is refused |
| `--env-file PATH` | Advanced override; must remain mode `0600` |
| `--no-color` | Disable ANSI colour (also honours `NO_COLOR`) |
| `--quiet` | Only errors and requested output |
| `--json` | Machine-readable output where supported |
| `--yes` | Skip non-destructive confirmations; never bypasses data-purge confirmation |
| `--dry-run` | Show actions without changing state (start/stop/update/uninstall) |
| `-h`, `--help` | Usage |
| `--version` | CLI version |

---

## Implementation notes

- **Language:** a Bash entrypoint is sufficient for the first release because
  the underlying operations are process orchestration. It can later be replaced
  by a compiled binary without changing the command contract.
- **Delegation:** reuse `scripts/install.sh` and `scripts/uninstall.sh`; do not
  fork their logic. Shared helpers can move to `scripts/lib/` when the CLI is
  implemented.
- **No daemon:** every command is a short-lived process. No background service,
  socket or privileged helper is introduced.
- **No `eval`:** configuration is read with `awk`, never sourced.
- **Secret hygiene:** secret values are never printed, logged, or passed on the
  command line (where they would appear in `ps`). They stay in `.env` and are
  consumed by Compose.
- **Locking:** mutating commands take the same `~/.sentinelforge/.install.lock`
  used by the installer to prevent concurrent operations.
- **Health model:** container health plus HTTP checks (`/healthz`, `/`, and a
  `POST /api/v1/auth/login` validation response). Timeouts are configurable.
- **Exit codes:**
  - `0` success
  - `1` runtime or health failure
  - `2` usage/validation error
  - `3` not installed / missing configuration
  - `4` operation cancelled by the user
- **Compatibility:** the CLI reads only documented `.env` keys and the Compose
  file schema. It must not depend on container names, which Compose may change.
- **Packaging:** install the launcher into `~/.local/bin` with mode `0755`;
  provide an uninstall path for the launcher that leaves the installation
  directory intact.
- **Testing:** extend `scripts/tests/install-test.sh` with stubbed Docker tests
  for each command, including failure paths, idempotency, confirmation prompts,
  and secret-suppression checks.

---

## Non-goals for the first CLI release

- Kubernetes management (use `kubectl` and Argo CD).
- Multi-host orchestration or high availability.
- TLS certificate issuance.
- Automatic background updates.
- User administration (use the web UI or documented SQL promotion).
- Replacing Docker Compose as the source of truth for the running stack.

---

## Migration path from manual commands

| Manual operation | Planned CLI |
| :--- | :--- |
| `./scripts/install.sh` | `sentinelforge install` |
| `docker compose ... up -d` | `sentinelforge start` |
| `docker compose ... stop` | `sentinelforge stop` |
| `docker compose ... restart` | `sentinelforge restart` |
| `docker compose ... ps` | `sentinelforge status` |
| `docker compose ... logs -f` | `sentinelforge logs` |
| `pull && migrate && up -d` | `sentinelforge update` |
| `pg_dump ...` | `sentinelforge backup` |
| `pg_restore ...` | `sentinelforge restore` |
| `./scripts/uninstall.sh` | `sentinelforge uninstall` |

Until the CLI ships, use the exact commands in
[docs/installation.md](installation.md).
