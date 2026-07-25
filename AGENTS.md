# AGENTS.md

## Cursor Cloud specific instructions

**Communication language:** always communicate with the user in Russian (per their explicit
preference).

`rw-backup-full` is a single product: a Bash CLI backup/restore toolkit for Remnawave panels
and Telegram-bot Docker-Compose projects, plus a small FastAPI **web console** (`web/app.py`).
Authoritative docs are in Russian (`README-RU.md`); short overview in `README.md`.
In production it is deployed via `install.sh` (systemd) or the container image
(`container/Dockerfile`); for local development none of that is needed.

### Services

- **Web console (FastAPI, `web/app.py`)** — the only long-running service and the main thing
  to run/interact with in dev. It is a fleet-management UI on `127.0.0.1:8787`. Production
  install is `web/install-web.sh` (root-only, systemd); for dev, run `app.py` directly.
- The CLI (`scripts/rw-backup-full.sh`) and its per-component scripts operate on Docker, live
  PostgreSQL containers and S3 — those are only meaningful on a real fleet host and are not
  required for local dev/testing.

### Running the web console in dev

Run the app directly with the project venv (do NOT run `install.sh`/`install-web.sh`, which are
root/systemd installers):

```bash
mkdir -p "$HOME/rw-install"   # RW_INSTALL_DIR must already exist (see gotcha below)
WEB_TOKEN=devtoken123 RW_WEB_HOST=127.0.0.1 RW_WEB_PORT=8787 \
  RW_WEB_DATA="$HOME/rw-web-data" RW_INSTALL_DIR="$HOME/rw-install" \
  ~/.venvs/rw-backup-web/bin/python web/app.py
```

Non-obvious gotchas:
- **`WEB_TOKEN` is mandatory** — the app calls `raise SystemExit(...)` on startup if it is unset,
  so it will refuse to start with no token.
- **`RW_INSTALL_DIR` must exist before you add/edit any fleet data.** The fleet state file
  (`$RW_INSTALL_DIR/fleet.json`) is written via a sibling temp file, so writes fail with a
  `FileNotFoundError` if the directory is missing (endpoints like `POST /api/servers` 500).
  Create it once (`mkdir -p`) before use.
- All API endpoints require the token via `?token=...` or an `x-token` header; requests without
  it return `401`.
- Server "status" and most actions SSH into real fleet hosts, so they show offline/errors for
  fake IPs — that is expected in a dev environment with no reachable fleet.

### Tests

No test framework; tests are plain Bash scripts under `test/`, run directly (they mock
Docker/AWS/Postgres, so no live services are needed):

```bash
bash test/unit_menu_and_journals.sh   # fast unit checks — all pass
bash test/full_e2e_test.sh            # full backup→verify→s3 cycle
```

Note: `test/full_e2e_test.sh` has **pre-existing failures at this commit** — it references
functions that no longer exist in `scripts/rw-backup-full.sh` (e.g. `verify_custom_archive`,
`maybe_encrypt_for_upload`), so parts fail with `rc=127` / `unbound variable`. This is a
test/code mismatch, not an environment problem; do not "fix" it as part of env setup.
`test/unit_menu_and_journals.sh` passes fully.

### Lint

Shell scripts are ShellCheck-aware (inline `# shellcheck` directives) but there is no committed
lint config or CI. Lint/syntax-check manually:

```bash
shellcheck scripts/**/*.sh scripts/*.sh install.sh   # warnings (e.g. SC2034) are expected
bash -n scripts/rw-backup-full.sh                    # syntax check
```

### Sandbox / verify-stack notes

- **`verify-stack --db-mode pitr` is long-running by design** (download basebackup + WAL sync +
  Postgres recovery, up to ~10 min). After v5.5.2 it emits step progress and a recovery
  heartbeat every 30s; silence after `поднимаю БД из базового бэкапа + WAL` means an older
  build without that logging — update `scripts/sandbox/verify-stack.sh` before debugging as a
  hang.
- Live PITR smoke needs Docker + S3-compatible storage (MinIO is fine); unit tests under
  `test/` mock these and do not exercise real recovery.

### Environment notes

- System tools `shellcheck`, `age`/`age-keygen`, `zstd`, `jq`, and `python3.12-venv` are part of
  the dev environment (tests need `age`; lint needs `shellcheck`).
- Python deps for the web console (`fastapi`, `uvicorn`, `pydantic`) live in the venv at
  `~/.venvs/rw-backup-web`. There is no `requirements.txt`; the startup update script keeps this
  venv current.
