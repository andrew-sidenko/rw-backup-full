#!/usr/bin/env python3
"""rw-backup-full v5 — веб-сервис контроля и управления парком серверов.

Работает на сервере-песочнице. Модель доступа: веб-сервис ходит на
прод-серверы по SSH (ключ, форсированная команда не требуется) и вызывает
там CLI rw-backup-full. На прод-серверах НЕ открывается ни одного порта.

Функции:
  - список серверов, добавление/удаление (servers.json)
  - статус каждого сервера: rw-backup-full status --json по SSH
  - просмотр и редактирование конфигов (rw-backup-full.env, instances.d/*, s3.d/*)
  - запуск операций: panel-backup, custom-backup, basebackup, verify, wal-status
  - сводка результатов песочницы (локальные метрики .prom)

Безопасность: доступ по токену (WEB_TOKEN), слушает 127.0.0.1 по умолчанию —
наружу выводить только через reverse-proxy с TLS или VPN (NetBird и т.п.).
Редактирование конфигов и запуск операций — это и есть «управление», поэтому
токен обязателен: без WEB_TOKEN сервис не стартует.
"""

import json
import os
import time
import re
import shlex
import subprocess
import glob
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, Depends
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel
import uvicorn

INSTALL_DIR = os.environ.get("RW_INSTALL_DIR", "/opt/rw-backup-restore")
DATA_DIR = Path(os.environ.get("RW_WEB_DATA", f"{INSTALL_DIR}/web-data"))
SERVERS_FILE = DATA_DIR / "servers.json"          # legacy, мигрируется
FLEET_FILE = Path(os.environ.get("RW_FLEET_FILE", f"{INSTALL_DIR}/fleet.json"))
MANIFEST_CACHE = DATA_DIR / "manifest-cache.json"
MANIFEST_TTL = int(os.environ.get("RW_MANIFEST_TTL", "600"))  # сек
SSH_KEY = os.environ.get("RW_WEB_SSH_KEY", str(DATA_DIR / "id_ed25519"))
WEB_TOKEN = os.environ.get("WEB_TOKEN", "")
METRICS_DIR = os.environ.get("RW_METRICS_DIR", "/var/lib/node_exporter/textfile_collector")
SSH_TIMEOUT = int(os.environ.get("RW_WEB_SSH_TIMEOUT", "60"))

# Команды, которые разрешено запускать на серверах. Белый список —
# веб-интерфейс не даёт исполнять произвольные команды.
ALLOWED_ACTIONS = {
    "status":        ["rw-backup-full", "status", "--json"],
    "wal-status":    ["rw-backup-full", "wal-status"],
    "panel-backup":  ["rw-backup-full", "panel-backup"],
    "custom-backup": ["rw-backup-full", "custom-backup"],
    "backup-all":    ["rw-backup-full", "backup-all"],
    "verify-local":  ["rw-backup-full", "verify", "--local"],
    "metrics-export": ["rw-backup-full", "metrics-export"],
    "s3-backends":   ["rw-backup-full", "s3-backends"],
    "list":          ["rw-backup-full", "list"],
}
# Долгие операции получают увеличенный таймаут.
LONG_ACTIONS = {"panel-backup", "custom-backup", "backup-all", "verify-local"}

# Файлы, которые разрешено читать/редактировать (относительно INSTALL_DIR).
CONFIG_WHITELIST = [
    r"^rw-backup-full\.env$",
    r"^instances\.d/[a-zA-Z0-9_-]+\.env$",
    r"^s3\.d/[a-zA-Z0-9_-]+\.env$",
]

DATA_DIR.mkdir(parents=True, exist_ok=True)
if not WEB_TOKEN:
    raise SystemExit("WEB_TOKEN не задан. Задайте в /etc/rw-backup-web.env и перезапустите сервис.")

app = FastAPI(title="rw-backup-full fleet", docs_url=None, redoc_url=None)


def auth(request: Request):
    tok = request.headers.get("x-token") or request.query_params.get("token", "")
    if tok != WEB_TOKEN:
        raise HTTPException(401, "bad token")


DEFAULT_SETTINGS = {
    # Настройки проверок песочницы; сервер посвящён только песочнице и
    # управлению, поэтому глубину/параллелизм можно поднимать смело.
    "depth": "standard",        # quick | standard | deep
    "parallel": 2,              # одновременных проверок
    "history": 1,               # сколько последних архивов проверять на источник (deep: 3+)
    "schedule": "05:30",        # времена запуска verify (список через пробел)
    "tg_summary": {"token": "", "chat_id": ""},   # сводный отчёт песочницы (опц.)
}


def load_fleet() -> dict:
    """fleet.json — ЕДИНСТВЕННЫЙ файл состояния этого сервера (компактный,
    переносимый). Миграция из legacy servers.json выполняется прозрачно."""
    if FLEET_FILE.exists():
        d = json.loads(FLEET_FILE.read_text())
    elif SERVERS_FILE.exists():
        d = {"version": 1, "settings": dict(DEFAULT_SETTINGS),
             "servers": json.loads(SERVERS_FILE.read_text()).get("servers", [])}
        save_fleet(d)
    else:
        d = {"version": 1, "settings": dict(DEFAULT_SETTINGS), "servers": []}
    for k, v in DEFAULT_SETTINGS.items():
        d.setdefault("settings", {}).setdefault(k, v)
    return d


def save_fleet(data: dict):
    tmp = FLEET_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    tmp.replace(FLEET_FILE)
    os.chmod(FLEET_FILE, 0o600)


def load_servers() -> dict:
    return {"servers": load_fleet()["servers"]}


def save_servers(data: dict):
    fleet = load_fleet()
    fleet["servers"] = data["servers"]
    save_fleet(fleet)


def get_server(sid: str) -> dict:
    for s in load_servers()["servers"]:
        if s["id"] == sid:
            return s
    raise HTTPException(404, f"server {sid} not found")


def ssh_run(server: dict, argv: list[str], timeout: int = SSH_TIMEOUT,
            stdin_data: str | None = None) -> tuple[int, str, str]:
    """SSH-вызов с белым списком команд. argv собирается нами, не пользователем."""
    if server.get("type", "ssh") != "ssh":
        raise HTTPException(501, "транспорт k8s зарезервирован под будущий переезд; "
                                 "k8s-источники мониторятся через S3/песочницу/Grafana")
    dest = f"{server.get('user', 'root')}@{server['host']}"
    cmd = [
        "ssh", "-i", SSH_KEY,
        "-p", str(server.get("port", 22)),
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=accept-new",
        dest,
        " ".join(shlex.quote(a) for a in argv),
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, input=stdin_data)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s"


def check_config_path(rel: str) -> str:
    rel = rel.strip("/")
    if not any(re.match(pat, rel) for pat in CONFIG_WHITELIST):
        raise HTTPException(400, "путь вне белого списка конфигов")
    return f"{INSTALL_DIR}/{rel}"


class ServerIn(BaseModel):
    id: str
    host: str
    user: str = "root"
    port: int = 22
    note: str = ""
    # Транспорт: "ssh" — текущие хосты; "k8s" зарезервирован под облачную
    # инфраструктуру (kubeconfig-транспорт появится вместе с переездом;
    # мониторинг k8s-источников уже сейчас идёт через общую S3-схему,
    # песочницу и Grafana).
    type: str = "ssh"


class ConfigIn(BaseModel):
    content: str


# ---------------------------------------------------------------- API

@app.get("/api/servers", dependencies=[Depends(auth)])
def api_servers():
    return load_servers()


@app.post("/api/servers", dependencies=[Depends(auth)])
def api_add_server(srv: ServerIn):
    if not re.match(r"^[a-zA-Z0-9_-]+$", srv.id):
        raise HTTPException(400, "id: только латиница/цифры/дефис")
    data = load_servers()
    if any(s["id"] == srv.id for s in data["servers"]):
        raise HTTPException(409, "id уже существует")
    data["servers"].append(srv.model_dump())
    save_servers(data)
    return {"ok": True}


@app.delete("/api/servers/{sid}", dependencies=[Depends(auth)])
def api_del_server(sid: str):
    data = load_servers()
    before = len(data["servers"])
    data["servers"] = [s for s in data["servers"] if s["id"] != sid]
    if len(data["servers"]) == before:
        raise HTTPException(404, "not found")
    save_servers(data)
    return {"ok": True, "note": "удалена только запись в веб-сервисе; сам сервер не изменён"}


@app.get("/api/servers/{sid}/status", dependencies=[Depends(auth)])
def api_status(sid: str):
    srv = get_server(sid)
    rc, out, err = ssh_run(srv, ALLOWED_ACTIONS["status"])
    if rc != 0:
        return JSONResponse({"ok": False, "error": err.strip() or f"rc={rc}"}, status_code=502)
    try:
        return {"ok": True, "status": json.loads(out.strip().splitlines()[-1])}
    except Exception:
        return JSONResponse({"ok": False, "error": "невалидный JSON от сервера", "raw": out[-2000:]},
                            status_code=502)


@app.get("/api/servers/{sid}/journals", dependencies=[Depends(auth)])
def api_journals(sid: str):
    """Список .txt-журналов в S3 сервера (по SSH: rw-backup-full journals)."""
    srv = get_server(sid)
    rc, out, err = ssh_run(srv, ["rw-backup-full", "journals"])
    if rc != 0:
        return JSONResponse({"ok": False, "error": err.strip() or f"rc={rc}"}, status_code=502)
    try:
        return {"ok": True, "journals": json.loads(out.strip().splitlines()[-1])}
    except Exception:
        return JSONResponse({"ok": False, "error": "невалидный JSON от сервера", "raw": out[-2000:]},
                            status_code=502)


@app.get("/api/servers/{sid}/journal", dependencies=[Depends(auth)])
def api_journal(sid: str, backend: str, key: str):
    """Содержимое одного журнала из S3. Ключ валидируется и здесь, и в CLI."""
    if not re.match(r"^[a-zA-Z0-9_-]+$", backend):
        raise HTTPException(400, "bad backend")
    if not key.endswith(".txt") or ".." in key or "/" not in key:
        raise HTTPException(400, "bad key")
    srv = get_server(sid)
    rc, out, err = ssh_run(srv, ["rw-backup-full", "journal-show", backend, key])
    if rc != 0:
        return JSONResponse({"ok": False, "error": err.strip() or f"rc={rc}"}, status_code=502)
    return {"ok": True, "content": out[-20000:]}


@app.post("/api/servers/{sid}/action/{action}", dependencies=[Depends(auth)])
def api_action(sid: str, action: str):
    if action not in ALLOWED_ACTIONS:
        raise HTTPException(400, f"действие не в белом списке: {sorted(ALLOWED_ACTIONS)}")
    srv = get_server(sid)
    timeout = 1800 if action in LONG_ACTIONS else SSH_TIMEOUT
    rc, out, err = ssh_run(srv, ALLOWED_ACTIONS[action], timeout=timeout)
    return {"ok": rc == 0, "rc": rc, "stdout": out[-8000:], "stderr": err[-4000:]}


@app.get("/api/servers/{sid}/configs", dependencies=[Depends(auth)])
def api_list_configs(sid: str):
    srv = get_server(sid)
    rc, out, _ = ssh_run(srv, ["ls", f"{INSTALL_DIR}/instances.d/", f"{INSTALL_DIR}/s3.d/"])
    files = ["rw-backup-full.env"]
    cur = None
    for line in out.splitlines():
        line = line.strip()
        if line.endswith(":"):
            cur = "instances.d" if "instances.d" in line else "s3.d"
        elif line.endswith(".env") and cur:
            files.append(f"{cur}/{line}")
    return {"ok": rc == 0, "files": files}


@app.get("/api/servers/{sid}/config", dependencies=[Depends(auth)])
def api_get_config(sid: str, path: str):
    srv = get_server(sid)
    full = check_config_path(path)
    rc, out, err = ssh_run(srv, ["cat", full])
    if rc != 0:
        raise HTTPException(502, err.strip() or "read failed")
    # Секреты маскируются при просмотре; при сохранении маска-строки не перезаписывают значения.
    masked = re.sub(r'((?:SECRET|TOKEN|PASSWORD|ACCESS)_?[A-Z_]*=")[^"]+(")',
                    r"\1***MASKED***\2", out)
    return {"ok": True, "path": path, "content": masked}


@app.put("/api/servers/{sid}/config", dependencies=[Depends(auth)])
def api_put_config(sid: str, path: str, body: ConfigIn):
    srv = get_server(sid)
    full = check_config_path(path)
    # Строки с ***MASKED*** не должны затирать реальные секреты:
    # такие строки выбрасываются, значения на сервере остаются прежними.
    lines = [l for l in body.content.splitlines() if "***MASKED***" not in l]
    keep_keys = [l.split("=")[0] for l in body.content.splitlines() if "***MASKED***" in l]
    script = f"""set -e
f={shlex.quote(full)}
[ -f "$f" ] && cp -a "$f" "$f.web-backup.$(date +%s)"
tmp=$(mktemp)
cat > "$tmp" <<'RW_WEB_EOF'
{os.linesep.join(lines)}
RW_WEB_EOF
"""
    # Дописываем сохранённые секретные строки из текущего файла.
    for key in keep_keys:
        script += f'grep -E "^{key}=" "$f" >> "$tmp" 2>/dev/null || true\n'
    script += 'mv "$tmp" "$f"\nchmod 600 "$f"\necho SAVED'
    rc, out, err = ssh_run(srv, ["bash", "-s"], stdin_data=script)
    if rc != 0 or "SAVED" not in out:
        raise HTTPException(502, err.strip() or "write failed")
    return {"ok": True, "note": "старая версия сохранена рядом (*.web-backup.<ts>); "
                                "маскированные секреты не изменены"}


@app.get("/api/fleet/settings", dependencies=[Depends(auth)])
def api_get_settings():
    return {"ok": True, "settings": load_fleet()["settings"]}


@app.put("/api/fleet/settings", dependencies=[Depends(auth)])
def api_put_settings(body: dict):
    fleet = load_fleet()
    allowed = set(DEFAULT_SETTINGS)
    for k, v in (body or {}).items():
        if k in allowed:
            fleet["settings"][k] = v
    save_fleet(fleet)
    return {"ok": True, "settings": fleet["settings"]}


@app.get("/api/fleet/manifest", dependencies=[Depends(auth)])
def api_fleet_manifest(force: int = 0):
    """Агрегированный манифест парка для verify-fleet: по каждому серверу —
    его источник, S3-бэкенды с реквизитами, инстансы с типами, Telegram.
    Собирается по SSH (rw-backup-full fleet-manifest), кэшируется."""
    if not force and MANIFEST_CACHE.exists():
        try:
            cached = json.loads(MANIFEST_CACHE.read_text())
            if time.time() - cached.get("collected_at", 0) < MANIFEST_TTL:
                return cached
        except Exception:
            pass

    fleet = load_fleet()
    out = {"ok": True, "collected_at": int(time.time()),
           "settings": fleet["settings"], "servers": []}
    for srv in fleet["servers"]:
        entry = {"id": srv["id"], "type": srv.get("type", "ssh"), "reachable": False}
        if srv.get("type", "ssh") != "ssh":
            entry["error"] = "k8s transport not implemented yet"
            out["servers"].append(entry)
            continue
        rc, so, se = ssh_run(srv, ["rw-backup-full", "fleet-manifest"])
        if rc == 0:
            try:
                entry.update(json.loads(so.strip().splitlines()[-1]))
                entry["reachable"] = True
            except Exception:
                entry["error"] = "invalid manifest json"
        else:
            entry["error"] = (se or f"rc={rc}").strip()[-300:]
        out["servers"].append(entry)

    MANIFEST_CACHE.write_text(json.dumps(out, ensure_ascii=False))
    os.chmod(MANIFEST_CACHE, 0o600)
    return out


@app.get("/api/sandbox/summary", dependencies=[Depends(auth)])
def api_sandbox_summary():
    """Последние результаты песочницы из локальных .prom-файлов."""
    result = {}
    for f in glob.glob(f"{METRICS_DIR}/rw_sandbox_*.prom") + glob.glob(f"{METRICS_DIR}/rw_fleet_*.prom"):
        for line in Path(f).read_text().splitlines():
            if line.startswith("#") or not line.strip():
                continue
            m = re.match(r"^(\w+)(\{[^}]*\})?\s+([-\d.]+)", line)
            if m:
                result[m.group(1) + (m.group(2) or "")] = float(m.group(3))
    # Кэш кредов: когда последний раз синхронизировали
    creds_root = Path(INSTALL_DIR) / "fleet-creds"
    creds = {}
    if creds_root.is_dir():
        for d in creds_root.iterdir():
            if d.is_dir() and (d / "synced_at").exists():
                try:
                    creds[d.name] = int((d / "synced_at").read_text().strip())
                except Exception:
                    creds[d.name] = 0
    return {"ok": True, "metrics": result, "creds_synced": creds}


@app.get("/api/fleet/overview", dependencies=[Depends(auth)])
def api_fleet_overview():
    """Сводка парка для панели управления: серверы, проверки, ошибки."""
    fleet = load_fleet()
    summary = api_sandbox_summary()
    metrics = summary.get("metrics", {})
    servers_out = []
    for srv in fleet["servers"]:
        entry = {"id": srv["id"], "host": srv.get("host"), "note": srv.get("note", ""),
                 "type": srv.get("type", "ssh")}
        # Статус по SSH (короткий таймаут)
        try:
            rc, out, err = ssh_run(srv, ALLOWED_ACTIONS["status"], timeout=20)
            if rc == 0:
                entry["status"] = json.loads(out.strip().splitlines()[-1])
                entry["reachable"] = True
            else:
                entry["reachable"] = False
                entry["error"] = (err or f"rc={rc}")[-200:]
        except Exception as e:
            entry["reachable"] = False
            entry["error"] = str(e)[:200]
        # Метрики проверок по этому source
        src = (entry.get("status") or {}).get("host") or srv["id"]
        fails = [k for k, v in metrics.items()
                 if k.startswith("rw_fleet_verify_ok{") and f'source="{src}"' in k and v == 0.0]
        entry["verify_fails"] = len(fails)
        entry["creds_synced_at"] = summary.get("creds_synced", {}).get(srv["id"])
        servers_out.append(entry)
    return {
        "ok": True,
        "settings": fleet["settings"],
        "servers": servers_out,
        "fleet_checks_total": metrics.get("rw_fleet_verify_checks_total"),
        "fleet_checks_passed": metrics.get("rw_fleet_verify_checks_passed"),
        "fleet_last_run": metrics.get("rw_fleet_verify_last_run_timestamp_seconds"),
    }


HISTORY_DIR = Path(os.environ.get(
    "VERIFY_HISTORY_DIR", f"{INSTALL_DIR}/web-data/verify-history"))


def _load_history(limit: int = 20, server: str | None = None) -> list[dict]:
    """Читает JSON-историю прогонов fleet/stack (новые сверху)."""
    if not HISTORY_DIR.is_dir():
        return []
    files = sorted(
        list(HISTORY_DIR.glob("fleet_*.json")) + list(HISTORY_DIR.glob("stack_*.json")),
        key=lambda p: p.stat().st_mtime, reverse=True)
    out = []
    for f in files:
        if len(out) >= limit:
            break
        try:
            data = json.loads(f.read_text())
        except Exception:
            continue
        if server:
            # fleet: фильтр по results[].source; stack: по source
            if data.get("type") == "fleet":
                filtered = [r for r in data.get("results", [])
                            if r.get("source") == server]
                if not filtered:
                    continue
                data = dict(data)
                data["results"] = filtered
                data["total"] = len(filtered)
                data["passed"] = sum(1 for r in filtered if r.get("ok"))
            elif data.get("source") != server and data.get("project") != server:
                continue
        data["_file"] = f.name
        out.append(data)
    return out


@app.get("/api/verify/history", dependencies=[Depends(auth)])
def api_verify_history(limit: int = 20, server: str | None = None):
    """История проверок восстановимости (fleet + stack) для панели."""
    limit = max(1, min(limit, 100))
    return {"ok": True, "history": _load_history(limit, server)}


@app.get("/api/servers/{sid}/verify", dependencies=[Depends(auth)])
def api_server_verify(sid: str, limit: int = 10):
    """История проверок, относящихся к конкретному серверу."""
    get_server(sid)  # 404 если нет
    limit = max(1, min(limit, 50))
    # Ищем и по id карточки, и по hostname из статуса (source в S3).
    hist = _load_history(limit * 3, server=sid)
    # Дополнительно — по source из последнего статуса / манифеста
    try:
        rc, out, _ = ssh_run(get_server(sid), ALLOWED_ACTIONS["status"], timeout=15)
        if rc == 0:
            st = json.loads(out.strip().splitlines()[-1])
            src = st.get("host")
            if src and src != sid:
                extra = _load_history(limit * 3, server=src)
                seen = {h.get("_file") for h in hist}
                for h in extra:
                    if h.get("_file") not in seen:
                        hist.append(h)
    except Exception:
        pass
    hist.sort(key=lambda h: h.get("ts", 0), reverse=True)
    return {"ok": True, "server": sid, "history": hist[:limit]}


@app.get("/api/pubkey", dependencies=[Depends(auth)])
def api_pubkey():
    pub = Path(SSH_KEY + ".pub")
    return {"ok": pub.exists(), "pubkey": pub.read_text().strip() if pub.exists() else ""}


# ---------------------------------------------------------------- UI

INDEX_HTML = """<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>rw-backup-full — парк серверов</title><style>
:root{--bg:#0f1419;--card:#1a2129;--tx:#dbe4ee;--mut:#7d8b99;--ok:#3fb950;--bad:#f85149;--ac:#58a6ff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.5 system-ui,sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:20px}
h1{font-size:20px}h1 small{color:var(--mut);font-weight:400}
.card{background:var(--card);border:1px solid #2b3742;border-radius:10px;padding:14px;margin:12px 0}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:12px}
button{background:#22303c;border:1px solid #35434f;color:var(--tx);border-radius:6px;padding:6px 10px;cursor:pointer;margin:2px}
button:hover{border-color:var(--ac)}button.pri{background:var(--ac);color:#04121f;border-color:var(--ac)}
input,textarea,select{background:#0d1319;border:1px solid #35434f;color:var(--tx);border-radius:6px;padding:6px 8px;width:100%}
textarea{font-family:ui-monospace,monospace;min-height:320px}
.ok{color:var(--ok)}.bad{color:var(--bad)}.mut{color:var(--mut)}
pre{background:#0d1319;padding:10px;border-radius:6px;overflow:auto;max-height:340px;white-space:pre-wrap}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
dialog{background:var(--card);color:var(--tx);border:1px solid #35434f;border-radius:10px;max-width:820px;width:92%}
::backdrop{background:#000a}
.badge{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;background:#22303c}
</style></head><body><div class="wrap">
<h1>rw-backup-full <small>— контроль и управление парком серверов</small></h1>
<div class="card"><div class="row">
<input id="tok" placeholder="Токен доступа" style="max-width:280px" type="password">
<button class="pri" onclick="saveTok()">Войти</button>
<button onclick="refreshAll()">⟳ Обновить всё</button>
<button onclick="showPubkey()">SSH-ключ сервиса</button>
<button onclick="addDlg.showModal()">+ Добавить сервер</button>
</div></div>
<div class="card"><b>Песочница (этот сервер):</b> <span id="sandbox" class="mut">…</span></div>
<div class="card"><b>Парк (сводно):</b> <span id="fleet" class="mut">…</span></div>
<div class="card"><b>История проверок:</b>
<button onclick="loadHistory()">⟳</button>
<div id="history" class="mut">…</div></div>
<div id="servers" class="grid"></div>
<pre id="log" class="mut">Журнал операций…</pre>

<dialog id="addDlg"><h3>Добавить сервер</h3>
<p class="mut">Перед добавлением установите на сервер публичный SSH-ключ сервиса
(кнопка «SSH-ключ сервиса») в ~/.ssh/authorized_keys пользователя.</p>
<div class="row"><select id="a_type" style="max-width:120px"><option value="ssh">ssh-хост</option><option value="k8s">k8s (скоро)</option></select>
<input id="a_id" placeholder="id (например prod-panel-1)">
<input id="a_host" placeholder="host / IP"><input id="a_user" placeholder="user" value="root">
<input id="a_port" placeholder="порт" value="22"><input id="a_note" placeholder="заметка"></div>
<div class="row"><button class="pri" onclick="addServer()">Добавить</button>
<button onclick="addDlg.close()">Отмена</button></div></dialog>

<dialog id="cfgDlg"><h3 id="cfgTitle"></h3>
<select id="cfgFile" onchange="loadCfg()"></select>
<textarea id="cfgBody"></textarea>
<p class="mut">Секреты показаны как ***MASKED*** — при сохранении их значения на
сервере не изменяются. Перед записью на сервере создаётся резервная копия файла.</p>
<div class="row"><button class="pri" onclick="saveCfg()">Сохранить на сервер</button>
<button onclick="cfgDlg.close()">Закрыть</button></div></dialog>

<dialog id="histDlg"><h3 id="histTitle">Проверки</h3>
<pre id="histBody" style="max-height:420px"></pre>
<div class="row"><button onclick="histDlg.close()">Закрыть</button></div></dialog>

<dialog id="jrnDlg"><h3 id="jrnTitle">Журналы</h3>
<div id="jrnList" class="mut" style="max-height:200px;overflow:auto"></div>
<pre id="jrnBody" style="max-height:340px">выберите журнал…</pre>
<div class="row"><button onclick="jrnDlg.close()">Закрыть</button></div></dialog>

<script>
let TOK = localStorage.getItem('rwtok')||''; if(TOK) document.getElementById('tok').value = TOK;
let curSid = null;
const $ = id => document.getElementById(id);
const api = async (m, p, body) => {
  const r = await fetch(p, {method:m, headers:{'x-token':TOK,'content-type':'application/json'},
    body: body?JSON.stringify(body):undefined});
  if(r.status===401){log('⛔ Неверный токен'); throw 'auth';}
  return r.json();
};
const log = t => { $('log').textContent = new Date().toLocaleTimeString()+'  '+t+'\\n'+$('log').textContent; };
function saveTok(){ TOK=$('tok').value; localStorage.setItem('rwtok',TOK); refreshAll(); }

async function refreshAll(){
  const d = await api('GET','/api/servers');
  const box = $('servers'); box.innerHTML='';
  d.servers.forEach(s=>{
    const el = document.createElement('div'); el.className='card'; el.id='srv-'+s.id;
    el.innerHTML = `<b>${s.id}</b> <span class="badge">${s.type||'ssh'}</span> <span class="mut">${s.user}@${s.host}:${s.port}</span>
      <span class="badge" id="st-${s.id}">…</span>
      <div class="mut">${s.note||''}</div><div id="info-${s.id}" class="mut">загрузка статуса…</div>
      <div class="row">
      <button onclick="act('${s.id}','panel-backup')">Бэкап панели</button>
      <button onclick="act('${s.id}','custom-backup')">Бэкап ботов</button>
      <button onclick="act('${s.id}','wal-status')">WAL-статус</button>
      <button onclick="act('${s.id}','verify-local')">Verify</button>
      <button onclick="showServerVerify('${s.id}')">История проверок</button>
      <button onclick="openJournals('${s.id}')">Журналы</button>
      <button onclick="openCfg('${s.id}')">⚙ Конфиги</button>
      <button onclick="delServer('${s.id}')" class="bad">✕</button>
      </div>`;
    box.appendChild(el);
    loadStatus(s.id);
  });
  loadSandbox();
  loadHistory();
}
function fmtB(n){ if(n==null) return '—'; const u=['Б','КБ','МБ','ГБ','ТБ']; let i=0; n=+n; while(n>=1024&&i<u.length-1){n/=1024;i++;} return n.toFixed(i?1:0)+u[i]; }
function ago(ts,now){ if(!ts) return 'нет'; const s=now-ts; if(s<3600) return Math.round(s/60)+'м назад'; if(s<86400) return Math.round(s/3600)+'ч назад'; return Math.round(s/86400)+'д назад'; }
window._fleet = {};
function renderFleetTotals(){
  const v=Object.values(window._fleet); const el=$('fleet'); if(!el||!v.length) return;
  const online=v.filter(x=>x.online).length;
  const errs=v.reduce((a,x)=>a+(x.errors||0),0);
  const s3=v.reduce((a,x)=>a+(x.s3bytes||0),0);
  el.innerHTML = `серверов online: <b class="${online===v.length?'ok':'bad'}">${online}/${v.length}</b>`+
    ` · суммарно в S3: <b>${fmtB(s3)}</b>`+
    (errs?` · <b class="bad">ошибок: ${errs}</b>`:` · <span class="ok">ошибок нет</span>`);
}
async function loadStatus(sid){
  try{
    const r = await api('GET',`/api/servers/${sid}/status`);
    const b = $('st-'+sid), i = $('info-'+sid);
    if(!r.ok){ b.textContent='offline'; b.className='badge bad'; i.textContent=r.error||''; window._fleet[sid]={online:false}; renderFleetTotals(); return; }
    const st = r.status; const now = st.time||Math.floor(Date.now()/1000);
    b.textContent='online'; b.className='badge ok';
    const page = ago(st.panel.last_backup_ts, now);
    const comps = st.components || '—';
    const disk = st.disk_free_bytes!=null ? fmtB(st.disk_free_bytes)+' своб.' : '—';
    const locsz = st.local_backup_bytes!=null ? fmtB(st.local_backup_bytes) : '—';
    const errs = st.errors||0;
    const s3 = (st.s3_backends||[]).map(x=>{
      const warn = x.reachable===false?' <span class="bad">⚠ недоступен</span>':'';
      const off = x.enabled?'':'(off)';
      return `&nbsp;&nbsp;${x.name}${off}: <b>${fmtB(x.bytes)}</b> / ${x.objects||0} об.${warn}`;
    }).join('<br>') || '&nbsp;&nbsp;—';
    const wal = (st.wal_instances||[]).map(w=>
      `&nbsp;&nbsp;${w.name}: ${w.running?'▲':'▼'} spool=${w.spool} bb=${w.basebackups} · база ${ago(w.last_basebackup_ts,now)} · WAL ${ago(w.last_wal_ts,now)}`
    ).join('<br>') || '&nbsp;&nbsp;—';
    i.innerHTML = `компоненты: <code>${comps}</code>`+
      (errs?` · <b class="bad">ошибок: ${errs}</b>`:` · <span class="ok">ошибок нет</span>`)+`<br>`+
      `панель: ${st.panel.detected?'да':'нет'}, бэкап: ${page} · ботов-архивов: ${st.custom_archives}<br>`+
      `место: занято локально <b>${locsz}</b> · диск ${disk}<br>`+
      `S3-хранилища:<br>${s3}<br>`+
      `WAL:<br>${wal}`;
    const s3sum = (st.s3_backends||[]).reduce((a,x)=>a+(+x.bytes||0),0);
    window._fleet[sid]={online:true, errors:errs, s3bytes:s3sum};
    renderFleetTotals();
    loadServerVerdict(sid);
  }catch(e){ if(e!=='auth'){ $('st-'+sid).textContent='err'; $('st-'+sid).className='badge bad'; } }
}
async function loadServerVerdict(sid){
  try{
    const r = await api('GET',`/api/servers/${sid}/verify?limit=1`);
    const i = $('info-'+sid); if(!i||!r.history||!r.history.length) return;
    const h=r.history[0];
    const ok = h.type==='fleet' ? (h.passed===h.total) : h.ok;
    const when = h.ts? new Date(h.ts*1000).toLocaleString():'';
    i.innerHTML += `<br>последняя проверка: <b class="${ok?'ok':'bad'}">${ok?'ПРОЙДЕНА':'ОШИБКА'}</b> <span class="mut">${when}</span>`;
  }catch(e){}
}
async function loadSandbox(){
  const r = await api('GET','/api/sandbox/summary');
  const m = r.metrics||{};
  const tot = m['rw_fleet_verify_checks_total']?? m['rw_sandbox_checks_total']??'—';
  const pass = m['rw_fleet_verify_checks_passed']?? m['rw_sandbox_checks_passed']??'—';
  const ts = m['rw_fleet_verify_last_run_timestamp_seconds']?? m['rw_sandbox_last_run_timestamp_seconds'];
  const fails = Object.entries(m).filter(([k,v])=>k.includes('verify_ok')&&v===0).length;
  const synced = Object.keys(r.creds_synced||{}).length;
  $('sandbox').innerHTML = `проверок: <b class="${pass===tot?'ok':'bad'}">${pass}/${tot}</b>`+
    (fails?` · ошибок матрицы: <b class="bad">${fails}</b>`:'')+
    (ts?` · последний прогон: ${new Date(ts*1000).toLocaleString()}`:'')+
    ` · кредов синхр.: ${synced}`;
}
function fmtHist(h){
  const when = h.ts? new Date(h.ts*1000).toLocaleString() : h._file;
  if(h.type==='fleet'){
    const cls = h.passed===h.total?'ok':'bad';
    return `<div><span class="${cls}">fleet</span> ${when} — <b class="${cls}">${h.passed}/${h.total}</b> (depth=${h.depth||'?'})`+
      (h.results||[]).slice(0,8).map(r=>`<div class="mut" style="margin-left:12px">${r.ok?'✅':'❌'} ${r.source}: ${(r.detail||'').slice(0,120)}</div>`).join('')+
      `</div>`;
  }
  const cls = h.ok?'ok':'bad';
  return `<div><span class="${cls}">stack</span> ${when} — <b>${h.project||'?'}</b> src=${h.source||'?'} <span class="${cls}">${h.ok?'ok':'fail'}</span> <span class="mut">${h.detail||''}</span></div>`;
}
async function loadHistory(){
  try{
    const r = await api('GET','/api/verify/history?limit=12');
    const box = $('history');
    if(!r.history || !r.history.length){ box.innerHTML='<span class="mut">пока нет прогонов</span>'; return; }
    box.innerHTML = r.history.map(fmtHist).join('');
  }catch(e){ if(e!=='auth') $('history').textContent='ошибка загрузки истории'; }
}
async function showServerVerify(sid){
  $('histTitle').textContent = 'Проверки: '+sid;
  $('histBody').textContent = 'загрузка…';
  histDlg.showModal();
  const r = await api('GET',`/api/servers/${sid}/verify?limit=15`);
  if(!r.history || !r.history.length){ $('histBody').textContent='нет записей для этого сервера'; return; }
  $('histBody').textContent = r.history.map(h=>{
    if(h.type==='fleet'){
      return new Date((h.ts||0)*1000).toLocaleString()+' fleet '+h.passed+'/'+h.total+'\\n'+
        (h.results||[]).map(x=>'  '+(x.ok?'OK':'FAIL')+' '+(x.detail||'')).join('\\n');
    }
    return new Date((h.ts||0)*1000).toLocaleString()+' stack '+(h.ok?'OK':'FAIL')+' '+(h.project||'')+' '+(h.detail||'');
  }).join('\\n\\n');
}
async function openJournals(sid){
  $('jrnTitle').textContent = 'Журналы (S3): '+sid;
  $('jrnList').textContent = 'загрузка списка…';
  $('jrnBody').textContent = 'выберите журнал…';
  jrnDlg.showModal();
  const r = await api('GET',`/api/servers/${sid}/journals`);
  if(!r.ok){ $('jrnList').textContent = 'ошибка: '+(r.error||''); return; }
  const js = r.journals||[];
  if(!js.length){ $('jrnList').textContent = 'журналов в S3 не найдено'; return; }
  $('jrnList').innerHTML = js.map(j=>{
    const kb = j.size? (j.size/1024).toFixed(1)+'КБ' : '';
    return `<div><button onclick="showJournal('${sid}','${j.backend}','${encodeURIComponent(j.key)}')">${j.name}</button> `+
      `<span class="mut">[${j.category}] ${j.backend} · ${j.date} · ${kb}</span></div>`;
  }).join('');
}
async function showJournal(sid,backend,keyEnc){
  const key = decodeURIComponent(keyEnc);
  $('jrnBody').textContent = 'загрузка…';
  const r = await api('GET',`/api/servers/${sid}/journal?backend=${encodeURIComponent(backend)}&key=${encodeURIComponent(key)}`);
  $('jrnBody').textContent = r.ok ? (r.content||'(пусто)') : ('ошибка: '+(r.error||''));
}
async function act(sid,a){
  log(`▶ ${sid}: ${a}…`);
  const r = await api('POST',`/api/servers/${sid}/action/${a}`);
  log(`${r.ok?'✅':'❌'} ${sid}: ${a} (rc=${r.rc})\\n${(r.stdout||'').slice(-1500)}${r.stderr?'\\nERR: '+r.stderr.slice(-500):''}`);
  loadStatus(sid);
}
async function addServer(){
  const s = {id:$('a_id').value, host:$('a_host').value, user:$('a_user').value,
    port:+$('a_port').value||22, note:$('a_note').value, type:$('a_type').value};
  if(s.type==='k8s'){ log('ℹ k8s-транспорт появится вместе с переездом; пока добавляйте ssh-хосты'); return; }
  const r = await api('POST','/api/servers', s);
  if(r.ok){ addDlg.close(); refreshAll(); log('✅ Сервер добавлен: '+s.id); }
}
async function delServer(sid){
  if(!confirm(`Убрать ${sid} из списка веб-сервиса?\\nСам сервер и его бэкапы НЕ изменяются.`)) return;
  await api('DELETE',`/api/servers/${sid}`); refreshAll();
}
async function openCfg(sid){
  curSid = sid; $('cfgTitle').textContent = 'Конфиги: '+sid;
  const r = await api('GET',`/api/servers/${sid}/configs`);
  $('cfgFile').innerHTML = r.files.map(f=>`<option>${f}</option>`).join('');
  cfgDlg.showModal(); loadCfg();
}
async function loadCfg(){
  const r = await api('GET',`/api/servers/${curSid}/config?path=`+encodeURIComponent($('cfgFile').value));
  $('cfgBody').value = r.content||'';
}
async function saveCfg(){
  if(!confirm('Записать файл на сервер '+curSid+'?\\nСтарая версия будет сохранена рядом (*.web-backup.*).')) return;
  const r = await api('PUT',`/api/servers/${curSid}/config?path=`+encodeURIComponent($('cfgFile').value),
    {content: $('cfgBody').value});
  log((r.ok?'✅ Сохранено: ':'❌ Ошибка: ')+$('cfgFile').value+' @ '+curSid+(r.note?' — '+r.note:''));
}
async function showPubkey(){
  const r = await api('GET','/api/pubkey');
  prompt('Добавьте этот ключ в ~/.ssh/authorized_keys на каждом сервере:', r.pubkey||'ключ не создан');
}
if(TOK) refreshAll();
</script></div></body></html>"""


@app.get("/", response_class=HTMLResponse)
def index():
    return INDEX_HTML


if __name__ == "__main__":
    host = os.environ.get("RW_WEB_HOST", "127.0.0.1")
    port = int(os.environ.get("RW_WEB_PORT", "8787"))
    uvicorn.run(app, host=host, port=port, log_level="warning")
