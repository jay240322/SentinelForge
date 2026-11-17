# SentinelForge Installation Guide (Docker Compose)

This document describes the first supported self-hosted installation method for
SentinelForge: a single-host Docker Compose deployment.

Kubernetes, Minikube and Argo CD remain fully supported and are documented
separately in the [README](../README.md#kubernetes-deployment-minikube--argo-cd).

> **Status:** the installer and Compose stack are implemented and covered by an
> automated, Docker-stubbed test suite. A live end-to-end installation must be
> performed on a machine with a running Docker daemon before calling a specific
> release production-ready.

---

## Contents

- [Architecture](#architecture)
- [System requirements](#system-requirements)
- [Installation](#installation)
- [Installer options](#installer-options)
- [Configuration](#configuration)
- [Generated secrets](#generated-secrets)
- [Accessing SentinelForge](#accessing-sentinelforge)
- [Create or promote an administrator](#create-or-promote-an-administrator)
- [Lifecycle commands](#lifecycle-commands)
- [Updating SentinelForge](#updating-sentinelforge)
- [Viewing logs](#viewing-logs)
- [Backup and restore](#backup-and-restore)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [Known limitations](#known-limitations)

---

## Architecture

The Compose stack runs five containers on a private bridge network:

```
                    Host 127.0.0.1:8080
                            |
                    +-------v--------+
                    |    gateway     |  nginx-unprivileged
                    |  /     -> :3000|
                    |  /api  -> :8000|
                    +---+--------+---+
                        |        |
            +-----------v--+  +--v-----------+
            |   frontend   |  |   backend    |
            |  Next.js 16  |  |  FastAPI     |
            |    :3000     |  |    :8000     |
            +--------------+  +---+------+---+
                                  |      |
                        +---------v--+  +v---------+
                        | PostgreSQL |  |  Redis   |
                        |   :5432    |  |  :6379   |
                        +------------+  +----------+
```

Key properties:

- Only the **gateway** publishes a host port, and it binds to `127.0.0.1` by
  default.
- **PostgreSQL and Redis have no host ports.** They are reachable only from the
  Compose network.
- The gateway is required because Next.js rewrites are compiled into the
  published frontend image at build time. Routing `/api` at the gateway lets
  SentinelForge run unmodified published images.
- PostgreSQL and Redis data live in named Docker volumes:
  `<project>_postgres_data` and `<project>_redis_data`.
- The gateway, frontend and backend run as non-root users. Application
  containers drop all Linux capabilities and set `no-new-privileges`.

The default Compose project name is `sentinelforge`, so the volumes are normally
`sentinelforge_postgres_data` and `sentinelforge_redis_data`.

---

## System requirements

| Requirement | Minimum | Recommended |
| :--- | :--- | :--- |
| Operating system | Linux (x86_64/arm64), macOS, or Windows via WSL2 | Ubuntu 22.04/24.04 on WSL2 or native Linux |
| CPU | 2 cores | 4 cores |
| RAM | 2 GB | 4 GB or more |
| Free disk | 5 GB (installer refuses below this) | 10 GB or more |
| Docker | Docker Engine 24+ or Docker Desktop | Current stable release |
| Docker Compose | Compose v2 plugin (`docker compose`) | v2.20 or newer |
| Utilities | `curl`, `awk`, `mktemp`, `df`, `openssl` or `python3` | — |
| Shell | Bash 3.2 or newer | Bash 5.x on Linux |

On WSL2 with Docker Desktop, images and named volumes are stored in a VM on the
Windows host, not in the WSL filesystem. The installer detects this and checks
free space on the Windows drive (`/mnt/c`) instead of refusing the install
because the WSL virtual disk looks small.

Native Windows shells (PowerShell, CMD, Git Bash) are not supported. Use WSL2
with Docker Desktop WSL integration enabled, or a Linux host.

Verify prerequisites:

```bash
docker --version
docker compose version
docker info --format '{{.ServerVersion}}'
```

`docker info` must print a server version. If it prints a connection error, the
Docker daemon is not running or your user cannot access it.

**Do not run the installer with `sudo`.** It is designed to install into your
own home directory and to use your existing Docker access.

---

## Installation

### Option A: from a Git checkout (available now)

```bash
git clone https://github.com/jay240322/sentinelforge.git
cd sentinelforge
git switch feature/installer   # or the branch/tag that contains the installer
./scripts/install.sh
```

The installer reads deployment assets from the checkout (`deploy/`), so this
method does not depend on the network beyond pulling container images.

### Option B: piped installer (available after the installer is merged and published)

Once `scripts/install.sh` and `deploy/` exist on the default branch, the
official installation command will be:

```bash
curl -fsSL https://raw.githubusercontent.com/jay240322/sentinelforge/main/scripts/install.sh | bash
```

When the script is piped, it downloads `deploy/docker-compose.yml`,
`deploy/.env.example` and `deploy/config/nginx.conf` from the same Git ref. To
pin a release tag or branch explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/jay240322/sentinelforge/main/scripts/install.sh \
  | bash -s -- --ref v1.0.0
```

If you prefer to inspect the script before running it:

```bash
curl -fsSL https://raw.githubusercontent.com/jay240322/sentinelforge/main/scripts/install.sh -o install.sh
less install.sh
bash install.sh
```

### What the installer does

1. Detects the operating system and CPU architecture.
2. Verifies `docker`, Docker Compose v2, a reachable daemon, and free disk space.
3. Creates `~/.sentinelforge` with mode `0700` and takes an installer lock.
4. Installs the Compose file, gateway configuration, and a version marker.
5. Generates a new `.env` with mode `0600` containing cryptographically random
   database and JWT secrets. Existing `.env` files are reused byte-for-byte.
6. Validates the Compose configuration and checks that the chosen port is free.
7. Pulls images, starts PostgreSQL and Redis, and waits for their health checks.
8. Runs `alembic upgrade head` in a one-shot migration container.
9. Starts the full stack and waits for backend, frontend and gateway health.
10. Verifies that `/` serves the frontend and that `/api/v1/auth/login` reaches
    FastAPI, then prints the application URL and troubleshooting commands.

### Non-interactive install

All options have environment-variable equivalents, useful for automation:

```bash
SENTINELFORGE_PORT=9090 \
SENTINELFORGE_BIND=127.0.0.1 \
./scripts/install.sh
```

The installer never prompts for input. It also never prints secret values.

---

## Installer options

Run `./scripts/install.sh --help` for the authoritative list.

| Option | Default | Description |
| :--- | :--- | :--- |
| `--dir PATH` | `~/.sentinelforge` | Installation directory (Compose file, `.env`, gateway config) |
| `--port PORT` | `8080` | Public gateway port |
| `--bind ADDRESS` | `127.0.0.1` | Host bind address for the gateway |
| `--project-name NAME` | `sentinelforge` | Compose project name; determines volume names |
| `--tag TAG` | `latest` | Image tag applied to backend and frontend on a fresh install |
| `--ref REF` | `main` | Git ref used to download deployment assets when piped |
| `--assets-dir PATH` | auto-detected | Use deployment assets from a local directory |
| `--skip-pull` | off | Use locally built images (no registry pull) |
| `--skip-migrations` | off | Advanced: start without running Alembic |
| `--version` | — | Print installer version |
| `--help` | — | Print usage |

Environment variables: `SENTINELFORGE_HOME`, `SENTINELFORGE_PORT`,
`SENTINELFORGE_BIND`, `SENTINELFORGE_PROJECT`, `SENTINELFORGE_TAG`,
`SENTINELFORGE_REPO`, `SENTINELFORGE_REF`, `SENTINELFORGE_ASSETS_DIR`,
`SENTINELFORGE_HEALTH_TIMEOUT`, `SENTINELFORGE_VERIFY_TIMEOUT`,
`SENTINELFORGE_SKIP_PULL`, `SENTINELFORGE_SKIP_MIGRATIONS`.

Examples:

```bash
# Use a different port because 8080 is already taken
./scripts/install.sh --port 9090

# Expose on the LAN behind your own firewall/reverse proxy
./scripts/install.sh --bind 0.0.0.0 --port 8080

# Pin a release tag (must exist in the registry)
./scripts/install.sh --tag v1.0.0

# Install from a local asset directory (air-gapped or staged rollout)
./scripts/install.sh --assets-dir /srv/sentinelforge/deploy
```

### Re-running the installer

The installer is idempotent:

- An existing `.env` is validated and reused; secrets are **never** regenerated.
- An existing installation with a matching PostgreSQL volume is detected. If the
  `.env` is missing, the installer refuses to continue rather than generate a
  password that would not match the existing database.
- Unchanged deployment files are left untouched. Updated files are backed up as
  `<name>.bak.<UTC timestamp>` before being replaced.
- Containers and volumes are not recreated unnecessarily. `docker compose up -d`
  converges the stack.

---

## Configuration

The generated configuration lives at `~/.sentinelforge/.env` with mode `0600`.

| Variable | Purpose | Generated |
| :--- | :--- | :--- |
| `COMPOSE_PROJECT_NAME` | Compose project name and volume prefix | yes |
| `SENTINELFORGE_PORT` | Public gateway port | yes |
| `SENTINELFORGE_BIND` | Gateway host bind address | yes |
| `SENTINELFORGE_BACKEND_IMAGE` | Backend image reference | yes |
| `SENTINELFORGE_FRONTEND_IMAGE` | Frontend image reference | yes |
| `SENTINELFORGE_GATEWAY_IMAGE` | Gateway image reference | yes |
| `POSTGRES_USER` | PostgreSQL role | yes |
| `POSTGRES_PASSWORD` | PostgreSQL password | yes, random |
| `POSTGRES_DB` | PostgreSQL database | yes |
| `JWT_SECRET_KEY` | JWT signing key | yes, random |
| `JWT_ALGORITHM` | JWT algorithm (`HS256`) | yes |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | Access token lifetime | yes |
| `REFRESH_TOKEN_EXPIRE_DAYS` | Refresh token lifetime | yes |

Edit non-secret values with care:

```bash
chmod 600 ~/.sentinelforge/.env
${EDITOR:-vi} ~/.sentinelforge/.env
```

After changing the port or bind address, re-run `./scripts/install.sh` so the
stack is reconciled. The installer also accepts `--port` and `--bind` and
persists those values into the existing `.env`.

**Do not change `POSTGRES_PASSWORD` after the first start.** PostgreSQL reads it
only when initializing an empty data directory. Changing it later does not
change the password inside PostgreSQL and the backend will fail to authenticate.
The same applies to `POSTGRES_USER` and `POSTGRES_DB`.

**Do not change `COMPOSE_PROJECT_NAME` after the first start.** It selects the
volume names; changing it would point the stack at new, empty volumes and make
existing data appear lost. The installer refuses this change.

The Compose file also uses these optional `SENTINELFORGE_*` image variables. Pin
immutable release tags (or digests) in production instead of `latest`.

---

## Generated secrets

On a fresh install the installer generates, using `openssl rand -hex 32` or the
Python `secrets` module as a fallback:

- `POSTGRES_PASSWORD`: 32 random bytes, hex encoded (64 characters)
- `JWT_SECRET_KEY`: 32 random bytes, hex encoded (64 characters)

Both are independently generated, URL-safe, written directly into `.env`, and
never echoed to the terminal or written to logs. The installer validates their
length and rejects placeholder values such as `changeme` or
`replace_with_openssl_rand_hex_32`.

Permissions enforced by the installer:

| Path | Mode |
| :--- | :--- |
| `~/.sentinelforge` | `0700` |
| `~/.sentinelforge/.env` | `0600` |
| `~/.sentinelforge/.installer-version` | `0600` |
| `~/.sentinelforge/docker-compose.yml` | `0644` |
| `~/.sentinelforge/config/nginx.conf` | `0644` |

Secrets are injected into containers at runtime through the environment. They
are never baked into images and never committed to Git.

---

## Accessing SentinelForge

After a successful install:

- Web UI: `http://localhost:8080`
- API base: `http://localhost:8080/api/v1`
- Gateway health: `http://localhost:8080/healthz`

If you installed with a different bind address, replace `localhost` with that
address. The installer prints the exact URL.

Quick verification:

```bash
curl -fsS http://localhost:8080/healthz
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/
curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST http://localhost:8080/api/v1/auth/login \
  -H 'Content-Type: application/json' -d '{}'
```

Expected results: `ok`, `200` (or a redirect), and `422` (request validation,
which proves the request reached FastAPI).

---

## Create or promote an administrator

The installer does not create an account and does not embed default
credentials. Register the first user through the web UI or API:

```bash
curl -fsS -X POST http://localhost:8080/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"choose-a-long-unique-password"}'
```

Then promote that account to `admin`. The easiest way is an interactive `psql`
session inside the PostgreSQL container:

```bash
docker compose \
  --project-name sentinelforge \
  --env-file "$HOME/.sentinelforge/.env" \
  -f "$HOME/.sentinelforge/docker-compose.yml" \
  exec postgres psql -U sentinelforge -d sentinelforge
```

At the `sentinelforge=#` prompt:

```sql
UPDATE users
SET role = 'admin', is_verified = true
WHERE email = 'you@example.com';

SELECT id, email, role, is_active, is_verified FROM users;
\q
```

Replace `sentinelforge` with your `POSTGRES_USER` and `POSTGRES_DB` values if
you changed them. The operation is intentionally manual: it requires database
access and never relies on a shared default password.

> **Security warning:** do not use `backend/scripts/create_admin.py`. It contains
> hard-coded credentials and is not part of the supported installation flow.

After promotion, sign out and back in so the new role is present in the issued
token/session.

---

## Lifecycle commands

The installer does not install a global CLI yet. Use Compose directly, or define
this shell helper once per session:

```bash
sf() {
  docker compose \
    --project-name sentinelforge \
    --env-file "$HOME/.sentinelforge/.env" \
    -f "$HOME/.sentinelforge/docker-compose.yml" "$@"
}
```

Then:

| Task | Command |
| :--- | :--- |
| Show status | `sf ps` |
| Start stopped containers | `sf start` |
| Stop containers (keeps containers and data) | `sf stop` |
| Restart everything | `sf restart` |
| Follow all logs | `sf logs -f --tail=100` |
| Follow one service | `sf logs -f --tail=100 backend` |
| Run migrations manually | `sf --profile tools run --rm migrate` |
| Remove containers and network (keeps volumes) | `../scripts/uninstall.sh` from a checkout, or `sf down --remove-orphans` |

Without the helper, expand the same command:

```bash
docker compose \
  --project-name sentinelforge \
  --env-file "$HOME/.sentinelforge/.env" \
  -f "$HOME/.sentinelforge/docker-compose.yml" \
  ps
```

The planned first-class CLI (`sentinelforge start|stop|status|logs|update|uninstall`)
is described in [docs/cli-design.md](cli-design.md). It is design-only in this
branch.

---

## Updating SentinelForge

### Recommended: pin and re-run the installer

1. Read the release notes and take a backup (see below).
2. Set the new image tags in `~/.sentinelforge/.env`:
   ```bash
   SENTINELFORGE_BACKEND_IMAGE=joypatel2403/sentinelforge-backend:v1.1.0
   SENTINELFORGE_FRONTEND_IMAGE=joypatel2403/sentinelforge-frontend:v1.1.0
   ```
   Or let the installer update both tags:
   ```bash
   ./scripts/install.sh --tag v1.1.0
   ```
3. Re-run the installer:
   ```bash
   ./scripts/install.sh
   ```
   It reuses secrets and volumes, pulls the new images, applies forward Alembic
   migrations, and waits for health checks.

### Manual update

```bash
cd ~/.sentinelforge
docker compose --env-file .env -f docker-compose.yml pull
docker compose --env-file .env -f docker-compose.yml \
  --profile tools run --rm migrate
docker compose --env-file .env -f docker-compose.yml up -d --remove-orphans
# Refresh gateway DNS resolution after backend/frontend recreation
docker compose --env-file .env -f docker-compose.yml restart gateway
```

### Rollback

Set the previous image tags in `.env` and re-run the installer, or run
`up -d` with the old tags. Database migrations are forward-only: if a release
changed the schema incompatibly, restore the pre-update backup before rolling
back the application.

---

## Viewing logs

```bash
docker compose \
  --project-name sentinelforge \
  --env-file "$HOME/.sentinelforge/.env" \
  -f "$HOME/.sentinelforge/docker-compose.yml" \
  logs -f --tail=100
```

Single service:

```bash
# Replace backend with gateway, frontend, postgres or redis
docker compose \
  --project-name sentinelforge \
  --env-file "$HOME/.sentinelforge/.env" \
  -f "$HOME/.sentinelforge/docker-compose.yml" \
  logs -f --tail=100 backend
```

Container logs are rotated: each service keeps three files of at most 10 MB.

Never paste raw logs into issues without checking them for tokens, email
addresses, or request bodies. The installer itself suppresses migration output
if it detects either generated secret in that output.

---

## Backup and restore

### Backup

Create a private backup directory and take a custom-format PostgreSQL dump:

```bash
umask 077
mkdir -p "$HOME/sentinelforge-backups"
chmod 700 "$HOME/sentinelforge-backups"

docker compose \
  --project-name sentinelforge \
  --env-file "$HOME/.sentinelforge/.env" \
  -f "$HOME/.sentinelforge/docker-compose.yml" \
  exec -T postgres pg_dump -U sentinelforge -d sentinelforge \
  --format=custom \
  > "$HOME/sentinelforge-backups/sentinelforge-$(date -u +%Y%m%dT%H%M%SZ).dump"

chmod 600 "$HOME/sentinelforge-backups/"*.dump
```

Adjust `-U` and `-d` if you changed `POSTGRES_USER` or `POSTGRES_DB`.

Back up configuration **separately**, because `.env` contains secrets:

```bash
umask 077
tar -czf "$HOME/sentinelforge-backups/config-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" \
  -C "$HOME" .sentinelforge/.env \
  .sentinelforge/docker-compose.yml \
  .sentinelforge/config
```

Store configuration backups encrypted (for example with `age` or `gpg`) and
never commit them. A database dump contains user accounts, audit logs, and
security alerts; treat it as sensitive data.

### Restore

Restoring overwrites the current schema. Take a fresh backup first, and stop the
backend to prevent writes during the restore:

```bash
# 1. Stop the application (database stays up)
docker compose \
  --project-name sentinelforge \
  --env-file "$HOME/.sentinelforge/.env" \
  -f "$HOME/.sentinelforge/docker-compose.yml" stop backend frontend gateway

# 2. Restore the dump
docker compose \
  --project-name sentinelforge \
  --env-file "$HOME/.sentinelforge/.env" \
  -f "$HOME/.sentinelforge/docker-compose.yml" \
  exec -T postgres pg_restore -U sentinelforge -d sentinelforge \
  --clean --if-exists --no-owner \
  < "$HOME/sentinelforge-backups/REPLACE-WITH-YOUR.dump"

# 3. Restart the application
docker compose \
  --project-name sentinelforge \
  --env-file "$HOME/.sentinelforge/.env" \
  -f "$HOME/.sentinelforge/docker-compose.yml" start
```

Then verify the UI, login, and the health endpoint. If the restore was intended
to rebuild after a failed upgrade, keep the old images pinned until verification
completes.

### Configuration restore

Extract the configuration backup over `~/.sentinelforge`, then restore
permissions:

```bash
chmod 700 "$HOME/.sentinelforge"
chmod 600 "$HOME/.sentinelforge/.env"
```

The `.env` password must match the password inside the restored PostgreSQL data.
Restore the database and configuration backups together.

---

## Uninstall

The uninstaller never deletes data or configuration unless you explicitly ask
for it. From a checkout:

```bash
./scripts/uninstall.sh
```

It prints what will be removed, asks you to type `uninstall`, then runs
`docker compose down --remove-orphans`. It preserves:

- PostgreSQL data volume (`<project>_postgres_data`)
- Redis data volume (`<project>_redis_data`)
- The installation directory and `.env`
- All Kubernetes resources and PVCs (this script never touches them)

Options:

```bash
# Show what would happen without changing anything
./scripts/uninstall.sh --dry-run

# Skip the non-destructive confirmation (does NOT bypass purge confirmation)
./scripts/uninstall.sh --yes

# Also delete PostgreSQL and Redis volumes (destructive)
./scripts/uninstall.sh --purge-data
```

`--purge-data` prints a warning, lists the volumes selected for deletion, removes
containers and the network first, and then requires you to type `DELETE DATA`.
If you decline, containers stay stopped and volumes remain intact.

Purging deletes **all** user accounts, audit logs, security alerts and
configuration stored in PostgreSQL. There is no undo. Take a backup first.

The installation directory is always preserved, even with `--purge-data`.
Remove it manually only after storing any configuration you need:

```bash
rm -rf "$HOME/.sentinelforge"
```

### Remove Kubernetes resources

Kubernetes is managed separately. Do **not** delete the PostgreSQL PVC unless you
intend to destroy its data:

```bash
kubectl delete -f k8s/
# Leave the PVC in place to preserve data.
```

---

## Troubleshooting

### `Docker is not installed` or `daemon is not running`

```bash
docker --version
docker info --format '{{.ServerVersion}}'
```

Start Docker Engine or Docker Desktop. On Linux, if you see a permission error
for `/var/run/docker.sock`:

```bash
sudo usermod -aG docker "$USER"
# Log out and back in, or start a new shell with the new group:
newgrp docker
```

Then re-run the installer **without `sudo`**.

### `Docker Compose v2 is not available`

Install the Compose v2 plugin. It is provided by the `docker-compose-plugin`
package on most distributions and is included with Docker Desktop. The legacy
`docker-compose` v1 binary is not supported.

```bash
docker compose version
```

### `TCP port ... is already in use`

Find the listener:

```bash
ss -ltnp | grep ':8080'
```

Choose another port:

```bash
./scripts/install.sh --port 9090
```

If the port is used by this SentinelForge installation, the installer recognizes
that and continues.

### Containers are unhealthy

```bash
docker compose \
  --project-name sentinelforge \
  --env-file "$HOME/.sentinelforge/.env" \
  -f "$HOME/.sentinelforge/docker-compose.yml" \
  ps

# Then inspect the failing service:
docker compose \
  --project-name sentinelforge \
  --env-file "$HOME/.sentinelforge/.env" \
  -f "$HOME/.sentinelforge/docker-compose.yml" \
  logs --tail=100 backend
```

Services and health checks:

| Service | Health check |
| :--- | :--- |
| `postgres` | `pg_isready` |
| `redis` | `redis-cli ping` |
| `backend` | `GET http://127.0.0.1:8000/health` |
| `frontend` | `GET http://127.0.0.1:3000/` |
| `gateway` | `GET http://127.0.0.1:8080/healthz` |

### `Database migration failed`

The installer prints the tail of the migration output, unless it detects a
generated secret in that output. Common causes:

- **The backend image does not contain Alembic files.** Images published before
  Alembic support was added to `backend/Dockerfile` cannot run
  `alembic upgrade head`. The installer prints a hint when it detects this.
  Use an image built from the current branch, or build locally:
  ```bash
  docker build -t joypatel2403/sentinelforge-backend:local backend
  # then set in ~/.sentinelforge/.env:
  # SENTINELFORGE_BACKEND_IMAGE=joypatel2403/sentinelforge-backend:local
  ./scripts/install.sh --skip-pull
  ```
- **The database is unreachable.** Check `postgres` health and credentials.
- **A migration genuinely failed.** Inspect:
  ```bash
  docker compose \
    --project-name sentinelforge \
    --env-file "$HOME/.sentinelforge/.env" \
    -f "$HOME/.sentinelforge/docker-compose.yml" \
    --profile tools run --rm migrate
  ```

### `Refusing to generate new credentials`

The installer found existing containers or a PostgreSQL volume for the project
but no `.env`. Generating a new password would not match the existing database.
Recovery options:

1. Restore `~/.sentinelforge/.env` from backup and re-run.
2. If you know the original database password, recreate `.env` manually with the
   matching `POSTGRES_PASSWORD` and a fresh `JWT_SECRET_KEY`, then re-run.
3. If you intentionally want to discard existing data, use
   `scripts/uninstall.sh --purge-data` and then reinstall.

Never delete a volume just to make an error go away.

### `This installation already uses project ...`

Changing `COMPOSE_PROJECT_NAME` would orphan existing volumes. Revert the value,
or perform a deliberate migration of the data to a new project name.

### Frontend loads but API calls fail (404/502)

Check routing through the gateway:

```bash
curl -i http://localhost:8080/healthz
curl -i -X POST http://localhost:8080/api/v1/auth/login \
  -H 'Content-Type: application/json' -d '{}'
```

A `422` is expected. A `404` or `502` means the gateway cannot reach the backend.
Confirm both are healthy and that `config/nginx.conf` exists:

```bash
ls -l "$HOME/.sentinelforge/config/nginx.conf"
```

Re-run the installer to restore missing or outdated deployment files.

### WSL2 cannot reach Docker

Enable **Settings → Resources → WSL Integration** for your distribution in
Docker Desktop, then restart the WSL shell. Verify inside WSL:

```bash
docker info --format '{{.ServerVersion}}'
```

Do not run the installer from PowerShell or from a Windows path.

### `.env` permissions were changed

```bash
chmod 700 "$HOME/.sentinelforge"
chmod 600 "$HOME/.sentinelforge/.env"
```

The installer tightens `.env` to `0600` on every run.

### Account locked

SentinelForge locks an account for 15 minutes after repeated failed logins. Wait
for the lock to expire, or clear it explicitly as an administrator:

```sql
UPDATE users
SET failed_login_attempts = 0, locked_until = NULL
WHERE email = 'you@example.com';
```

### Out of disk space

Docker images and volumes consume space outside the installation directory:

```bash
docker system df
df -h "$HOME"
```

On WSL2 with Docker Desktop, check the Windows drive that hosts Docker's data
(usually `C:`) rather than the WSL filesystem:

```bash
df -h /mnt/c
```

Remove unused images with `docker image prune`, but never remove SentinelForge
volumes unless you intend to delete its data.

### Need more diagnostics

The installer does not print secrets. To share diagnostics, collect only
non-sensitive output:

```bash
docker compose \
  --project-name sentinelforge \
  --env-file "$HOME/.sentinelforge/.env" \
  -f "$HOME/.sentinelforge/docker-compose.yml" \
  ps

docker version
docker compose version
uname -a
```

Redact hostnames, emails, IP addresses, tokens and any `.env` content.

---

## Security notes

- **Loopback by default.** The gateway binds to `127.0.0.1`. Binding to
  `0.0.0.0` exposes the UI and API to your network; put a firewall and a TLS
  reverse proxy in front of it. The installer does not configure TLS.
- **No public database or cache.** PostgreSQL and Redis publish no host ports.
- **Secrets at rest.** `.env` is mode `0600` inside a mode `0700` directory. The
  installer refuses weak, empty, placeholder, or whitespace-containing secrets.
- **Secrets never printed.** The installer suppresses migration output if either
  generated secret appears in it.
- **No unsafe execution.** The installer does not use `eval`, does not source
  `.env`, and reads values with `awk` instead.
- **Non-root workloads.** Gateway, frontend and backend images run as non-root.
  Application containers drop all capabilities and set `no-new-privileges`;
  PostgreSQL and Redis also set `no-new-privileges`.
- **Pinned images.** `latest` is convenient for evaluation but not
  reproducible. Pin release tags or digests and review upstream changes before
  updating.
- **Rotating `JWT_SECRET_KEY`** invalidates all issued access and refresh tokens.
  Update `.env` and restart the backend:
  ```bash
  docker compose \
    --project-name sentinelforge \
    --env-file "$HOME/.sentinelforge/.env" \
    -f "$HOME/.sentinelforge/docker-compose.yml" \
    up -d --force-recreate backend
  ```
- **Rotating the database password** requires changing it inside PostgreSQL and
  updating `.env`. Changing only `.env` breaks the backend. Take a backup and
  use `ALTER USER ... WITH PASSWORD ...` in a `psql` session, then restart the
  backend. Never paste the new password into shell history; use `psql`'s
  interactive prompt or a protected file.
- **Backups are sensitive.** They contain credentials (configuration archive)
  and personal/security data (database dump). Encrypt them and restrict access.
- **Audit logs and alerts are append-only business data.** They live in
  PostgreSQL and are preserved by default uninstall.
- **No default administrator.** Promote accounts deliberately as shown above.
  Do not use `backend/scripts/create_admin.py`; it contains hard-coded
  credentials.
- **Supply chain.** The gateway image (`nginxinc/nginx-unprivileged`) and the
  official PostgreSQL/Redis images are pulled from Docker Hub. Verify digests in
  regulated environments. The piped installer trusts HTTPS plus the Git ref it
  downloads from; pin a release tag and inspect the script before running it.
  Published release artifacts should add checksums or signatures.

---

## Known limitations

- **Validated live on WSL2 + Docker Desktop, not yet on every platform.** An
  end-to-end install was completed on WSL2 (Ubuntu, x86_64, Docker Desktop,
  Compose v5.7). That run exercised real image pulls, PostgreSQL initialization,
  Alembic migrations, gateway routing, registration, login, role promotion, an
  idempotent re-run, and a non-destructive uninstall/reinstall cycle that
  preserved data. macOS, native Linux and arm64 hosts still need a live run
  before a release is declared production-ready, and the stub suite remains the
  regression baseline.
- **Published backend image may predate Alembic support.** The installer
  detects the failure and explains how to rebuild. CI must publish an updated
  backend image that contains `alembic.ini` and `alembic/`.
- **`curl | bash` is only available after merge/publication.** The command is
  documented with the real repository path, but it requires `scripts/install.sh`
  and `deploy/` to exist on the referenced branch or tag.
- **No built-in TLS or reverse proxy.** Use a trusted reverse proxy or ingress in
  front of the loopback port for remote access.
- **Single-host only.** This is not a high-availability deployment. Use the
  Kubernetes manifests for clustered operation.
- **No automatic backups or update scheduling.** Operators must schedule
  `pg_dump` and review releases.
- **No first-class `sentinelforge` CLI yet.** See
  [docs/cli-design.md](cli-design.md) for the planned interface.
- **No administrator bootstrap.** Account promotion is a deliberate manual
  database operation.
- **Published images are currently `linux/amd64` only.** The backend and
  frontend tags published on Docker Hub contain amd64 images. Apple Silicon and
  other arm64 hosts work only through Docker's amd64 emulation and may be slow.
  Multi-architecture publishing is a follow-up.
- **Rootless Docker and Podman are untested.** Docker Engine or Docker Desktop
  with Compose v2 is the supported runtime.
