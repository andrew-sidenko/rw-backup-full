# AGENTS.md

## Cursor Cloud specific instructions

`rw-backup-full` is a Bash-based backup/restore toolkit (wrapper around
`distillium/remnawave-backup-restore`) plus a Python FastAPI fleet-management web
service. Most user-facing text is in Russian; `README.md` is the English summary,
`README-RU.md` / `docs/*-RU.md` the detailed docs.

### Components & how to run them

- Bash CLI — `scripts/rw-backup-full.sh` (core product). Sub-scripts live in
  `scripts/{wal,panel,metrics,sandbox,track,host,lib}`. Commands are dispatched in
  the `case` block at the bottom of the file; run `bash scripts/rw-backup-full.sh help`.
- Web service — `web/app.py` (FastAPI + uvicorn). Fleet control panel that SSHes to
  prod hosts and invokes the CLI remotely. Serves an HTML UI + JSON API.

### Lint / test / build / run

- Lint (Bash): `shellcheck scripts/rw-backup-full.sh` (the scripts already carry
  `# shellcheck disable=` directives, so shellcheck is the intended linter). Add
  `-S error` to gate only on errors.
- Syntax check everything: `bash -n <file>` over `*.sh`; `python3 -m py_compile web/app.py`.
- Run the CLI (dev, no root): most commands require `docker`, EXCEPT `status --json`
  and `fleet-manifest`, which are the machine interfaces the web service consumes and
  run without docker. Override install paths via env vars, e.g.:
  `INSTALL_DIR=/tmp/rw-dev FULL_CONFIG_FILE=/tmp/rw-dev/rw-backup-full.env BACKUP_DIR=/tmp/rw-dev/backup bash scripts/rw-backup-full.sh status --json`
- Run the web service (dev): the venv lives at `$HOME/rw-web-venv` (created by the
  update script). It refuses to start without `WEB_TOKEN`. Point it at scratch dirs
  so it does not need the production `/opt/rw-backup-restore` layout:
  `WEB_TOKEN=devtoken123 RW_INSTALL_DIR=/tmp/rw-dev RW_WEB_DATA=/tmp/rw-dev/web-data RW_FLEET_FILE=/tmp/rw-dev/fleet.json RW_WEB_HOST=127.0.0.1 RW_WEB_PORT=8787 "$HOME/rw-web-venv/bin/python" web/app.py`
  Then the UI is at http://127.0.0.1:8787/ (send the token in the `x-token` header or
  the token field in the UI).

### Non-obvious caveats

- The e2e test `test/full_e2e_test.sh` is STALE: it was written for v4 and references
  functions that no longer exist in the current v5.4 script (`verify_custom_archive`,
  `maybe_encrypt_for_upload`, `primary_s3_upload`, `s3_list_custom_backups`). It fails
  with rc=127 / unbound-variable partway through. This is a pre-existing test/code
  mismatch, not an environment problem — do not treat its failure as a broken setup.
  The parts that reference still-existing functions (backup/restore/s3 upload/retention)
  do exercise real logic using mock `docker`/`aws` on `PATH` (real `age`/`tar`/`gzip`).
- `docker`, `awscli`, and a reachable S3/SSH host are only needed for real backups and
  for the web service to actually reach prod hosts. They are intentionally mocked in the
  test suite; the CLI's non-docker paths and the web service both run without them.
- The web service's remote-status calls will show servers as `offline` unless the
  service SSH key (`$RW_WEB_DATA/id_ed25519`) exists and the target host is reachable —
  expected in a dev/demo environment.
- System tools `age`, `shellcheck`, and `python3-venv` are installed at the OS level and
  persist via the VM snapshot; they are intentionally NOT in the update script (which
  only refreshes the Python web-service venv).
