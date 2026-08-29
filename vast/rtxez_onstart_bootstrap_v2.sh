#!/usr/bin/env bash
set -euo pipefail

LOG_ROOT="/workspace/minikrea2-tool/runtime/logs"
if [[ ! -e /workspace && -d /opt/workspace-internal ]]; then
  ln -sfn /opt/workspace-internal /workspace
fi

if [[ ! -d /workspace ]]; then
  mkdir -p /workspace
fi

TOOL_DIR="/workspace/minikrea2-tool"
RUNTIME_DIR="$TOOL_DIR/runtime"
STATE_DIR="$RUNTIME_DIR/state"
LOG_DIR="$RUNTIME_DIR/logs"
STATUS_JSON="$STATE_DIR/status.json"
COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
if [[ ! -d "$COMFYUI_DIR" && -d /opt/workspace-internal/ComfyUI ]]; then
  COMFYUI_DIR="/opt/workspace-internal/ComfyUI"
fi

mkdir -p "$TOOL_DIR" "$RUNTIME_DIR" "$STATE_DIR" "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/rtxez_onstart_bootstrap_v2.log") 2>&1

log() {
  printf '[rtxez-v2] %s\n' "$*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

PY_BIN="/venv/main/bin/python"
if [[ ! -x "$PY_BIN" ]]; then
  PY_BIN="$(command -v python3 || command -v python)"
fi

ln -sf "$PY_BIN" /usr/local/bin/python || true
ln -sf "$PY_BIN" /usr/local/bin/python3 || true

NODE_LOG="$LOG_DIR/rtxez_nodes.log"
MODEL_LOG="$LOG_DIR/rtxez_models.log"

json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/}"
  printf '%s' "$value"
}

update_status() {
  local phase="$1"
  local detail="${2:-}"
  cat > "$STATUS_JSON" <<EOF
{"phase":"$(json_escape "$phase")","detail":"$(json_escape "$detail")","updated_at":"$(date --iso-8601=seconds)","comfyui_dir":"$(json_escape "$COMFYUI_DIR")"}
EOF
}

write_status_portal() {
  cat > "$TOOL_DIR/status_portal.py" <<'EOF'
#!/usr/bin/env python3
import json
import os
import shutil
import socket
import socketserver
import time
from http.server import BaseHTTPRequestHandler

STATE_DIR = "/workspace/minikrea2-tool/runtime/state"
LOG_DIR = "/workspace/minikrea2-tool/runtime/logs"
STATUS_JSON = os.path.join(STATE_DIR, "status.json")
MODELS_DIR = "/workspace/ComfyUI/models"
PORTAL_PORT = int(os.environ.get("OPEN_BUTTON_PORT", "1111"))
APP_TARGETS = [
    {"name": "Instance Portal", "listen_port": PORTAL_PORT, "public_port_keys": [f"VAST_TCP_PORT_{PORTAL_PORT}", "VAST_TCP_PORT_11111"], "path": "/", "active": True},
    {"name": "ComfyUI", "listen_port": 18188, "public_port_keys": ["VAST_TCP_PORT_18188", "VAST_TCP_PORT_8188"], "path": "/", "active": False},
    {"name": "API Wrapper", "listen_port": 8288, "public_port_keys": ["VAST_TCP_PORT_8288"], "path": "/docs", "active": False},
    {"name": "Jupyter", "listen_port": 8080, "public_port_keys": ["VAST_TCP_PORT_8080"], "path": "/tree", "active": False},
    {"name": "Jupyter Terminal", "listen_port": 8080, "public_port_keys": ["VAST_TCP_PORT_8080"], "path": "/terminals/1", "active": False},
    {"name": "Syncthing", "listen_port": 8384, "public_port_keys": ["VAST_TCP_PORT_8384"], "path": "/", "active": False},
]
WATCH_FILES = [
    "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors",
    "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors",
    "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
    "vae/minimax_h3_video_vae_fp16.safetensors",
    "vae/minimax_h3_audio_vae_fp32.safetensors",
    "loras/minimax_h3_fl2v_lightx2v_turbo_4step_v0.1_comfy.safetensors",
    "loras/minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors",
    "vae_approx/taeh3.safetensors",
    "loras/HMNSFW_AIO_Sex_LoRA.safetensors",
    "loras/MysticXXX_MMH3-V4.safetensors",
]


def read_text(path, limit=120):
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        lines = handle.readlines()
    return lines[-limit:]


def read_status():
    if not os.path.exists(STATUS_JSON):
        return {
            "phase": "starting",
            "detail": "Status file not written yet.",
            "updated_at": "",
            "comfyui_dir": "",
        }
    with open(STATUS_JSON, "r", encoding="utf-8") as handle:
        return json.load(handle)


def html_escape(text):
    return (
        str(text)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def load_container_env():
    env = {}
    paths = ["/proc/1/environ", "/proc/self/environ"]
    for path in paths:
        try:
            raw = open(path, "rb").read().split(b"\0")
        except OSError:
            continue
        for item in raw:
            if b"=" not in item:
                continue
            key, value = item.split(b"=", 1)
            env[key.decode("utf-8", "ignore")] = value.decode("utf-8", "ignore")
        if env:
            break
    return env


CONTAINER_ENV = load_container_env()


def get_env(name, default=""):
    return os.environ.get(name) or CONTAINER_ENV.get(name) or default


def is_port_open(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.25)
        return sock.connect_ex(("127.0.0.1", int(port))) == 0


def get_request_origin(handler):
    host = handler.headers.get("Host", f"localhost:{PORTAL_PORT}")
    proto = handler.headers.get("X-Forwarded-Proto")
    if not proto:
        proto = "https" if handler.headers.get("X-Forwarded-For") else "http"
    return f"{proto}://{host.split('/')[0]}"


def get_public_host():
    return (
        get_env("PUBLIC_IPADDR")
        or get_env("VAST_PUBLIC_IP")
        or get_env("HOSTNAME")
        or "localhost"
    )


def get_public_port(app):
    for key in app.get("public_port_keys", []):
        value = get_env(key)
        if value:
            try:
                return int(value)
            except ValueError:
                pass
    return app["listen_port"]


def build_public_url(app):
    host = get_public_host()
    public_port = get_public_port(app)
    scheme = "https" if public_port in (443, 8443) else "http"
    return f"{scheme}://{host}:{public_port}{app['path']}"


def app_status(handler):
    request_origin = get_request_origin(handler)
    items = []
    for app in APP_TARGETS:
        request_base = request_origin.rsplit(":", 1)[0]
        tunnel_url = f"{request_base}:{PORTAL_PORT}{app['path']}" if app["active"] else f"{request_base}:{app['listen_port']}{app['path']}"
        items.append(
            {
                **app,
                "ready": is_port_open(app["listen_port"]),
                "public_port": get_public_port(app),
                "public_url": build_public_url(app),
                "tunnel_url": tunnel_url,
            }
        )
    return items


def tail_preview(path, limit=40):
    return "".join(read_text(path, limit))


def get_fs_usage(path):
    try:
        total, used, free = shutil.disk_usage(path)
        return {"total": total, "used": used, "free": free}
    except FileNotFoundError:
        return {"total": 0, "used": 0, "free": 0}


def format_bytes(num):
    num = float(num)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if num < 1024.0 or unit == "TB":
            return f"{num:.2f} {unit}" if unit != "B" else f"{int(num)} B"
        num /= 1024.0


def memory_info():
    try:
        data = {}
        with open("/proc/meminfo", "r", encoding="utf-8") as handle:
            for line in handle:
                key, value = line.split(":", 1)
                data[key] = int(value.strip().split()[0]) * 1024
        total = data.get("MemTotal", 0)
        available = data.get("MemAvailable", 0)
        used = max(total - available, 0)
        return {"total": total, "used": used, "free": available}
    except Exception:
        return {"total": 0, "used": 0, "free": 0}


def cpu_info():
    try:
        values = []
        with open("/proc/loadavg", "r", encoding="utf-8") as handle:
            parts = handle.read().strip().split()
        values = [float(parts[0]), float(parts[1]), float(parts[2])]
        return {"load1": values[0], "load5": values[1], "load15": values[2]}
    except Exception:
        return {"load1": 0.0, "load5": 0.0, "load15": 0.0}


def watch_model_files():
    rows = []
    for rel_path in WATCH_FILES:
        full_path = os.path.join(MODELS_DIR, rel_path)
        exists = os.path.exists(full_path)
        size = os.path.getsize(full_path) if exists else 0
        rows.append({"path": rel_path, "exists": exists, "size": size})
    return rows


def collect_payload(handler):
    status = read_status()
    workspace = get_fs_usage("/workspace")
    memory = memory_info()
    cpu = cpu_info()
    payload = {
        "status": status,
        "apps": app_status(handler),
        "workspace": workspace,
        "memory": memory,
        "cpu": cpu,
        "models": watch_model_files(),
        "logs": {
            "bootstrap": tail_preview(os.path.join(LOG_DIR, "rtxez_onstart_bootstrap_v2.log"), 80),
            "nodes": tail_preview(os.path.join(LOG_DIR, "rtxez_nodes.log"), 60),
            "models": tail_preview(os.path.join(LOG_DIR, "rtxez_models.log"), 60),
            "launcher": tail_preview(os.path.join(LOG_DIR, "onstart_launcher.log"), 40),
        },
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    return payload


def render_bar(used, total):
    pct = 0 if total <= 0 else min(max((used / total) * 100.0, 0), 100)
    return f"""
    <div class="stat-bar">
      <div class="stat-fill" style="width:{pct:.1f}%"></div>
    </div>
    <div class="meta">{format_bytes(used)} / {format_bytes(total)} ({pct:.1f}%)</div>
    """


def render_page(payload):
    status = payload["status"]
    apps = payload["apps"]
    model_rows = []
    for row in payload["models"]:
        state = "ready" if row["exists"] else "pending"
        model_rows.append(
            f"<tr><td>{html_escape(row['path'])}</td><td>{state}</td><td>{format_bytes(row['size'])}</td></tr>"
        )

    app_cards = []
    for app in apps:
        button = "Currently Active" if app["active"] else "Launch Application"
        disabled = "disabled" if app["active"] else ""
        status_class = "ok" if app["ready"] else "pending"
        primary_url = app["public_url"]
        app_cards.append(
            f"""
            <div class="card">
              <div class="card-header"><h2>{html_escape(app['name'])}</h2></div>
              <div class="launch-application">
                <a class="launch-btn" href="{html_escape(primary_url)}" target="_blank" {disabled}>{button}</a>
              </div>
              <div class="advanced-section open">
                <div class="advanced-label">Advanced Connection Options</div>
                <div class="advanced-details">
                  <div class="item">
                    <div>
                      <div>Public: {app['public_port']} | Local listen: {app['listen_port']}</div>
                      <div class="ip-info">Public URL: <a href="{html_escape(app['public_url'])}" target="_blank">{html_escape(app['public_url'])}</a></div>
                      <div class="ip-info">Tunnel URL: <a href="{html_escape(app['tunnel_url'])}" target="_blank">{html_escape(app['tunnel_url'])}</a></div>
                    </div>
                    <div class="pill {status_class}">{'ready' if app['ready'] else 'waiting'}</div>
                  </div>
                </div>
              </div>
            </div>
            """
        )

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta http-equiv="refresh" content="12">
  <title>MINIKrea2 Instance Portal</title>
  <style>
    :root {{
      --bg: #111827;
      --panel: #182132;
      --panel-2: #1d2739;
      --line: #2a354a;
      --text: #ecf2ff;
      --muted: #aab8d0;
      --brand: #5e78ff;
      --good: #31c48d;
      --warn: #f4b740;
      --bad: #f05d5e;
    }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; font-family: Inter, system-ui, sans-serif; background: var(--bg); color: var(--text); }}
    a {{ color: #c8d7ff; text-decoration: none; }}
    .layout {{ display: grid; grid-template-columns: 240px 1fr; min-height: 100vh; }}
    .sidebar {{ background: #101b2d; border-right: 1px solid var(--line); padding: 18px; }}
    .sidebar h1 {{ margin: 0 0 6px; font-size: 22px; }}
    .sidebar .meta {{ color: var(--muted); font-size: 14px; margin-bottom: 4px; }}
    .stat-item {{ margin: 16px 0; }}
    .stat-label {{ font-size: 13px; color: var(--muted); margin-bottom: 6px; }}
    .stat-bar {{ width: 100%; height: 6px; border-radius: 999px; background: #22304a; overflow: hidden; }}
    .stat-fill {{ height: 100%; background: linear-gradient(90deg, #31c48d, #5e78ff); }}
    .main {{ padding: 26px; }}
    .title {{ margin: 0 0 18px; font-size: 38px; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 18px; }}
    .card {{ background: var(--panel); border: 1px solid var(--line); border-radius: 14px; padding: 18px; }}
    .card-header h2 {{ margin: 0 0 18px; font-size: 18px; }}
    .launch-btn {{ display: inline-flex; justify-content: center; align-items: center; width: 100%; min-height: 48px; border-radius: 10px; background: var(--brand); color: white; font-weight: 700; }}
    .launch-btn[disabled] {{ pointer-events: none; background: #33415f; color: #d5ddf0; }}
    .advanced-section {{ margin-top: 16px; border-top: 1px solid var(--line); padding-top: 14px; }}
    .advanced-label {{ color: var(--muted); font-size: 13px; margin-bottom: 10px; }}
    .advanced-details .item {{ display: flex; justify-content: space-between; gap: 16px; align-items: center; }}
    .ip-info {{ color: var(--muted); font-size: 13px; margin-top: 4px; word-break: break-all; }}
    .pill {{ border-radius: 999px; padding: 6px 10px; font-size: 12px; font-weight: 700; text-transform: uppercase; }}
    .pill.ok {{ background: rgba(49,196,141,.12); color: #7ff0c1; }}
    .pill.pending {{ background: rgba(244,183,64,.12); color: #ffd16e; }}
    .split {{ display: grid; grid-template-columns: 1.15fr .85fr; gap: 18px; margin-top: 18px; }}
    .phase {{ font-size: 28px; color: #91a7ff; margin: 0 0 8px; }}
    .detail {{ color: var(--muted); line-height: 1.5; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{ text-align: left; padding: 10px 8px; border-bottom: 1px solid var(--line); font-size: 14px; }}
    th {{ color: var(--muted); font-weight: 600; }}
    pre {{ margin: 0; white-space: pre-wrap; word-break: break-word; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; color: #dbe6ff; }}
    .stack {{ display: grid; gap: 18px; }}
    .small {{ font-size: 12px; color: var(--muted); }}
    @media (max-width: 1100px) {{
      .layout {{ grid-template-columns: 1fr; }}
      .split {{ grid-template-columns: 1fr; }}
    }}
  </style>
</head>
<body>
  <div class="layout">
    <aside class="sidebar">
      <h1>Vast.ai</h1>
      <div class="meta">MINIKrea2 RTX-EZ</div>
      <div class="meta">Phase: {html_escape(status.get("phase", "unknown"))}</div>
      <div class="meta">Updated: {html_escape(status.get("updated_at", ""))}</div>
      <div class="stat-item">
        <div class="stat-label">Workspace Disk</div>
        {render_bar(payload["workspace"]["used"], payload["workspace"]["total"])}
      </div>
      <div class="stat-item">
        <div class="stat-label">Memory</div>
        {render_bar(payload["memory"]["used"], payload["memory"]["total"])}
      </div>
      <div class="stat-item">
        <div class="stat-label">CPU Load</div>
        <div class="small">load1 {payload["cpu"]["load1"]:.2f} | load5 {payload["cpu"]["load5"]:.2f} | load15 {payload["cpu"]["load15"]:.2f}</div>
      </div>
      <div class="stat-item">
        <div class="stat-label">Checks</div>
        <div class="small"><a href="/healthz">/healthz</a></div>
        <div class="small"><a href="/status.json">/status.json</a></div>
        <div class="small"><a href="/debug.json">/debug.json</a></div>
      </div>
    </aside>
    <main class="main">
      <h1 class="title">Applications</h1>
      <div class="grid">
        {''.join(app_cards)}
      </div>
      <div class="split">
        <div class="stack">
          <div class="card">
            <h2 class="phase">{html_escape(status.get("phase", "unknown"))}</h2>
            <div class="detail">{html_escape(status.get("detail", ""))}</div>
            <div class="small" style="margin-top:10px;">ComfyUI dir: {html_escape(status.get("comfyui_dir", ""))}</div>
          </div>
          <div class="card">
            <h2>Tracked Model Files</h2>
            <table>
              <thead><tr><th>Model</th><th>Status</th><th>Size</th></tr></thead>
              <tbody>{''.join(model_rows)}</tbody>
            </table>
          </div>
        </div>
        <div class="stack">
          <div class="card"><h2>Bootstrap Log</h2><pre>{html_escape(payload["logs"]["bootstrap"])}</pre></div>
          <div class="card"><h2>Node Log</h2><pre>{html_escape(payload["logs"]["nodes"])}</pre></div>
          <div class="card"><h2>Model Log</h2><pre>{html_escape(payload["logs"]["models"])}</pre></div>
        </div>
      </div>
    </main>
  </div>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, content_type, method="GET"):
        body_bytes = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body_bytes)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if method != "HEAD":
            self.wfile.write(body_bytes)

    def do_HEAD(self):
        if self.path in ("/", "/healthz", "/status.json", "/debug.json"):
            body = "{}" if self.path.endswith(".json") else "ok"
            content_type = "application/json" if self.path.endswith(".json") else "text/plain; charset=utf-8"
            self._send(200, body, content_type, method="HEAD")
            return
        self._send(404, "not found", "text/plain; charset=utf-8", method="HEAD")

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, "ok", "text/plain; charset=utf-8")
            return
        if self.path == "/status.json":
            self._send(200, json.dumps(read_status()), "application/json")
            return
        payload = collect_payload(self)
        if self.path == "/debug.json":
            self._send(200, json.dumps(payload, indent=2), "application/json")
            return
        body = render_page(payload)
        self._send(200, body, "text/html; charset=utf-8")

    def log_message(self, format, *args):
        return


class ReusableTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with ReusableTCPServer(("0.0.0.0", PORTAL_PORT), Handler) as httpd:
        httpd.serve_forever()
EOF
  chmod +x "$TOOL_DIR/status_portal.py"
}

start_status_portal() {
  write_status_portal
  if ! pgrep -f "$TOOL_DIR/status_portal.py" >/dev/null 2>&1; then
    nohup "$PY_BIN" "$TOOL_DIR/status_portal.py" >"$LOG_DIR/status_portal.log" 2>&1 </dev/null &
  fi
}

start_comfyui() {
  local port="18188"
  local args_string="${COMFYUI_ARGS:-"--disable-auto-launch --disable-xformers --port ${port} --enable-cors-header"}"
  if pgrep -f "$COMFYUI_DIR/main.py" >/dev/null 2>&1; then
    pkill -f "$COMFYUI_DIR/main.py" || true
    sleep 2
  fi
  update_status "starting_comfyui" "Starting ComfyUI on port ${port}."
  nohup bash -lc "\"$PY_BIN\" \"$COMFYUI_DIR/main.py\" --listen 0.0.0.0 ${args_string}" >"$LOG_DIR/comfyui.log" 2>&1 </dev/null &
}

wait_for_local_port() {
  local port="$1"
  local retries="${2:-60}"
  local delay="${3:-2}"
  local i
  for (( i=0; i<retries; i++ )); do
    if "$PY_BIN" - "$port" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.5)
try:
    sys.exit(0 if sock.connect_ex(("127.0.0.1", port)) == 0 else 1)
finally:
    sock.close()
PY
    then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

write_status_script() {
  cat > "$TOOL_DIR/check_rtxez_bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="/workspace/minikrea2-tool/runtime/logs"
echo "== bootstrap =="
tail -n 40 "$LOG_DIR/rtxez_onstart_bootstrap_v2.log" 2>/dev/null || true
echo
echo "== nodes =="
tail -n 40 "$LOG_DIR/rtxez_nodes.log" 2>/dev/null || true
echo
echo "== models =="
tail -n 40 "$LOG_DIR/rtxez_models.log" 2>/dev/null || true
echo
echo "== sizes =="
find /workspace/ComfyUI/models -type f 2>/dev/null | xargs -r du -h | sort -h | tail -n 30
EOF
  chmod +x "$TOOL_DIR/check_rtxez_bootstrap.sh"
}

hf_download() {
  local repo_id="$1"
  local repo_file="$2"
  local dest_dir="$3"
  local dest_name="${4:-$(basename "$repo_file")}"
  mkdir -p "$dest_dir"
  "$PY_BIN" - "$repo_id" "$repo_file" "$dest_dir" "$dest_name" <<'PY'
import os
import sys
import requests

repo_id, repo_file, dest_dir, dest_name = sys.argv[1:5]
token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
dest_path = os.path.join(dest_dir, dest_name)
os.makedirs(dest_dir, exist_ok=True)
url = f"https://huggingface.co/{repo_id}/resolve/main/{repo_file}"
headers = {}
if token:
    headers["Authorization"] = f"Bearer {token}"
with requests.get(url, headers=headers, stream=True, timeout=60, allow_redirects=True) as response:
    response.raise_for_status()
    with open(dest_path, "wb") as handle:
        for chunk in response.iter_content(chunk_size=16 * 1024 * 1024):
            if chunk:
                handle.write(chunk)
print(dest_path)
PY
}

civitai_download() {
  local version_id="$1"
  local dest_dir="$2"
  local dest_name="$3"
  mkdir -p "$dest_dir"
  "$PY_BIN" - "$version_id" "$dest_dir" "$dest_name" <<'PY'
import os
import shutil
import subprocess
import sys
from pathlib import Path

import requests


def build_browser_headers(token=None):
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/140.0.0.0 Safari/537.36"
        ),
        "Accept": "*/*",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def resolve_download_url(download_url, token):
    response = requests.get(
        download_url,
        headers=build_browser_headers(token),
        allow_redirects=False,
        timeout=60,
    )
    response.raise_for_status()
    if response.is_redirect or response.is_permanent_redirect:
        location = response.headers.get("Location")
        if not location:
            raise RuntimeError("Download URL redirected without a Location header.")
        return location
    return download_url

version_id, dest_dir, dest_name = sys.argv[1:4]
token = os.environ.get("CIVITAI_API_KEY") or os.environ.get("CIVITAI_TOKEN")
if not token:
    raise SystemExit("CIVITAI token missing")

base_url = os.environ.get("CIVITAI_BASE_URL", "https://civitai.red").rstrip("/")
session = requests.Session()
session.headers.update({"Authorization": f"Bearer {token}"})
resp = session.get(f"{base_url}/api/v1/model-versions/{version_id}", timeout=30)
resp.raise_for_status()
data = resp.json()
files = data.get("files") or []
if not files:
    raise SystemExit(f"No files in Civitai version {version_id}")

chosen = None
for item in files:
    if (item.get("name") or "").endswith(".safetensors"):
        chosen = item
        break
if chosen is None:
    chosen = files[0]

download_url = chosen.get("downloadUrl") or f"{base_url}/api/download/models/{version_id}"
dest_path = Path(dest_dir) / dest_name
if shutil.which("aria2c"):
    resolved_url = resolve_download_url(download_url, token)
    cmd = [
        "aria2c",
        "--allow-overwrite=true",
        "--auto-file-renaming=false",
        "--continue=true",
        "--split=16",
        "--max-connection-per-server=16",
        "--min-split-size=16M",
        "--file-allocation=none",
        "--summary-interval=10",
        "--retry-wait=3",
        "--max-tries=5",
        "--dir",
        str(dest_path.parent),
        "--out",
        dest_path.name,
        "--header",
        f"Authorization: Bearer {token}",
        "--header",
        "User-Agent: Mozilla/5.0",
        "--header",
        "Accept: */*",
        resolved_url,
    ]
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as exc:
        print(f"warning: aria2c failed with exit code {exc.returncode}, falling back to streamed download", file=sys.stderr)
        headers = build_browser_headers(token)
        with session.get(download_url, headers=headers, stream=True, timeout=120) as response:
            if response.status_code in (401, 403):
                response.close()
                response = requests.get(
                    resolved_url,
                    headers=build_browser_headers(),
                    stream=True,
                    timeout=120,
                )
            response.raise_for_status()
            with open(dest_path, "wb") as handle:
                for chunk in response.iter_content(chunk_size=16 * 1024 * 1024):
                    if chunk:
                        handle.write(chunk)
else:
    with session.get(download_url, headers=build_browser_headers(token), stream=True, timeout=120) as response:
        if response.status_code in (401, 403):
            response.close()
            response = requests.get(
                resolve_download_url(download_url, token),
                headers=build_browser_headers(),
                stream=True,
                timeout=120,
            )
        response.raise_for_status()
        with open(dest_path, "wb") as handle:
            for chunk in response.iter_content(chunk_size=16 * 1024 * 1024):
                if chunk:
                    handle.write(chunk)

print(dest_path)
PY
}

clone_or_update() {
  local repo_url="$1"
  local dest_dir="$2"
  if [[ -d "$dest_dir/.git" ]]; then
    git -C "$dest_dir" fetch --all --tags --prune
    git -C "$dest_dir" pull --ff-only
  else
    git clone --depth 1 "$repo_url" "$dest_dir"
  fi
}

install_requirements_if_present() {
  local dest_dir="$1"
  if [[ -f "$dest_dir/requirements.txt" ]]; then
    "$PY_BIN" -m pip install -r "$dest_dir/requirements.txt"
  fi
}

fix_torchvision() {
  local torch_version
  local torch_cuda
  local tv_version
  torch_version="$("$PY_BIN" - <<'PY'
import torch
print(torch.__version__.split('+')[0])
PY
)"
  torch_cuda="$("$PY_BIN" - <<'PY'
import torch
print((torch.version.cuda or "").replace(".", ""))
PY
)"
  tv_version="$("$PY_BIN" - "$torch_version" <<'PY'
import sys
major, minor, *_ = map(int, sys.argv[1].split("."))
print(f"0.{minor + 15}.0" if major == 2 else "")
PY
)"
  if [[ -n "$torch_cuda" && -n "$tv_version" ]]; then
    "$PY_BIN" -m pip install --force-reinstall --no-deps \
      --index-url "https://download.pytorch.org/whl/cu${torch_cuda}" \
      "torchvision==${tv_version}"
  fi
}

install_nodes() {
  : > "$NODE_LOG"
  update_status "installing_nodes" "Installing Python packages and ComfyUI custom nodes."
  log "node install start" | tee -a "$NODE_LOG"
  mkdir -p "$COMFYUI_DIR/custom_nodes"

  "$PY_BIN" -m pip install --upgrade pip setuptools wheel
  "$PY_BIN" -m pip install --upgrade "huggingface_hub[hf_transfer]" requests
  "$PY_BIN" -m pip install -U --pre comfyui-manager
  "$PY_BIN" -m pip install "kornia==0.8.2" nvidia-vfx

  clone_or_update "https://github.com/ltdrdata/ComfyUI-Manager.git" "$COMFYUI_DIR/custom_nodes/ComfyUI-Manager"
  clone_or_update "https://github.com/BobJohnson24/ComfyUI-INT8-Fast.git" "$COMFYUI_DIR/custom_nodes/ComfyUI-INT8-Fast"
  clone_or_update "https://github.com/kijai/ComfyUI-SolAttn_triton.git" "$COMFYUI_DIR/custom_nodes/ComfyUI-SolAttn_triton"
  clone_or_update "https://github.com/kijai/ComfyUI-KJNodes.git" "$COMFYUI_DIR/custom_nodes/ComfyUI-KJNodes"
  clone_or_update "https://github.com/rgthree/rgthree-comfy.git" "$COMFYUI_DIR/custom_nodes/rgthree-comfy"
  clone_or_update "https://github.com/yolain/ComfyUI-Easy-Use.git" "$COMFYUI_DIR/custom_nodes/ComfyUI-Easy-Use"
  clone_or_update "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git" "$COMFYUI_DIR/custom_nodes/ComfyUI-VideoHelperSuite"
  clone_or_update "https://github.com/Comfy-Org/Nvidia_RTX_Nodes_ComfyUI.git" "$COMFYUI_DIR/custom_nodes/Nvidia_RTX_Nodes_ComfyUI"
  clone_or_update "https://github.com/alexopus/ComfyUI-Image-Saver.git" "$COMFYUI_DIR/custom_nodes/ComfyUI-Image-Saver"

  install_requirements_if_present "$COMFYUI_DIR/custom_nodes/ComfyUI-Manager"
  install_requirements_if_present "$COMFYUI_DIR/custom_nodes/ComfyUI-INT8-Fast"
  install_requirements_if_present "$COMFYUI_DIR/custom_nodes/ComfyUI-SolAttn_triton"
  install_requirements_if_present "$COMFYUI_DIR/custom_nodes/ComfyUI-KJNodes"
  install_requirements_if_present "$COMFYUI_DIR/custom_nodes/rgthree-comfy"
  install_requirements_if_present "$COMFYUI_DIR/custom_nodes/ComfyUI-Easy-Use"
  install_requirements_if_present "$COMFYUI_DIR/custom_nodes/ComfyUI-VideoHelperSuite"
  install_requirements_if_present "$COMFYUI_DIR/custom_nodes/Nvidia_RTX_Nodes_ComfyUI"
  install_requirements_if_present "$COMFYUI_DIR/custom_nodes/ComfyUI-Image-Saver"

  fix_torchvision
  log "node install done" | tee -a "$NODE_LOG"
  update_status "nodes_ready" "Node installation and compatibility fixes completed."
}

download_models() {
  : > "$MODEL_LOG"
  update_status "downloading_models" "Starting large H3 model downloads."
  log "model download start" | tee -a "$MODEL_LOG"

  mkdir -p \
    "$COMFYUI_DIR/models/diffusion_models" \
    "$COMFYUI_DIR/models/text_encoders" \
    "$COMFYUI_DIR/models/vae" \
    "$COMFYUI_DIR/models/loras"

  hf_download "Comfy-Org/MiniMax-H3" "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" "$COMFYUI_DIR/models/diffusion_models" >>"$MODEL_LOG" 2>&1 &
  P1=$!
  hf_download "Comfy-Org/MiniMax-H3" "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" "$COMFYUI_DIR/models/diffusion_models" >>"$MODEL_LOG" 2>&1 &
  P2=$!
  hf_download "Comfy-Org/MiniMax-H3" "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" "$COMFYUI_DIR/models/text_encoders" >>"$MODEL_LOG" 2>&1 &
  P3=$!
  wait "$P1" "$P2" "$P3"

  hf_download "Comfy-Org/MiniMax-H3" "vae/minimax_h3_video_vae_fp16.safetensors" "$COMFYUI_DIR/models/vae" >>"$MODEL_LOG" 2>&1 &
  P4=$!
  hf_download "Comfy-Org/MiniMax-H3" "vae/minimax_h3_audio_vae_fp32.safetensors" "$COMFYUI_DIR/models/vae" >>"$MODEL_LOG" 2>&1 &
  P5=$!
  hf_download "Kijai/MiniMax-H3-TAE" "vae_approx/taeh3.safetensors" "$COMFYUI_DIR/models/vae_approx" >>"$MODEL_LOG" 2>&1 &
  P6=$!
  hf_download "Kijai/MiniMax-H3_comfy" "loras/minimax_h3_fl2v_lightx2v_turbo_4step_v0.1_comfy.safetensors" "$COMFYUI_DIR/models/loras" >>"$MODEL_LOG" 2>&1 &
  P7=$!
  civitai_download "3268303" "$COMFYUI_DIR/models/loras" "HMNSFW_AIO_Sex_LoRA.safetensors" >>"$MODEL_LOG" 2>&1 &
  P8=$!
  civitai_download "3266628" "$COMFYUI_DIR/models/loras" "MysticXXX_MMH3-V4.safetensors" >>"$MODEL_LOG" 2>&1 &
  P9=$!
  civitai_download "3252213" "$COMFYUI_DIR/models/loras" "HM_Pussy_Pussyanus_MMH3.safetensors" >>"$MODEL_LOG" 2>&1 &
  P10=$!
  civitai_download "3200540" "$COMFYUI_DIR/models/loras" "H3_Vagina_MMH3.safetensors" >>"$MODEL_LOG" 2>&1 &
  P11=$!
  wait "$P4" "$P5" "$P6" "$P7" "$P8" "$P9" "$P10" "$P11"

  log "model download done" | tee -a "$MODEL_LOG"
  update_status "models_ready" "All scheduled RTX-EZ models and LoRAs downloaded."
}

log "start $(date --iso-8601=seconds)"
log "workspace=$(readlink -f /workspace || echo /workspace)"
log "comfyui_dir=$COMFYUI_DIR"
if [[ -n "${HF_TOKEN:-}" ]]; then log "HF token detected"; else log "HF token missing"; fi
if [[ -n "${CIVITAI_API_KEY:-${CIVITAI_TOKEN:-}}" ]]; then log "Civitai token detected"; else log "Civitai token missing"; fi

update_status "booting" "Preparing workspace and installing system packages."
start_status_portal

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  aria2 \
  ca-certificates \
  curl \
  ffmpeg \
  git \
  jq \
  python3 \
  python3-pip \
  unzip

write_status_script

install_nodes
download_models

start_comfyui
if wait_for_local_port 18188 45 2; then
  update_status "complete" "Bootstrap finished. ComfyUI is listening on port 18188."
else
  update_status "comfyui_failed" "Bootstrap finished but ComfyUI did not open port 18188. Check comfyui.log."
fi
log "done $(date --iso-8601=seconds)"
