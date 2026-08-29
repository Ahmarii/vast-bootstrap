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
            "detail": "Portal is up. Bootstrap has not written status yet.",
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
    for path in ("/proc/1/environ", "/proc/self/environ"):
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
    payload = {
        "status": status,
        "apps": app_status(handler),
        "workspace": get_fs_usage("/workspace"),
        "memory": memory_info(),
        "cpu": cpu_info(),
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
    model_rows = []
    for row in payload["models"]:
        state = "ready" if row["exists"] else "pending"
        model_rows.append(
            f"<tr><td>{html_escape(row['path'])}</td><td>{state}</td><td>{format_bytes(row['size'])}</td></tr>"
        )

    app_cards = []
    for app in payload["apps"]:
        button = "Currently Active" if app["active"] else "Launch Application"
        disabled = "disabled" if app["active"] else ""
        status_class = "ok" if app["ready"] else "pending"
        app_cards.append(
            f"""
            <div class="card">
              <div class="card-header"><h2>{html_escape(app['name'])}</h2></div>
              <div class="launch-application">
                <a class="launch-btn" href="{html_escape(app['public_url'])}" target="_blank" {disabled}>{button}</a>
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
      --line: #2a354a;
      --text: #ecf2ff;
      --muted: #aab8d0;
      --brand: #5e78ff;
      --good: #31c48d;
      --warn: #f4b740;
    }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; font-family: Inter, system-ui, sans-serif; background: var(--bg); color: var(--text); }}
    a {{ color: #c8d7ff; text-decoration: none; }}
    .layout {{ display: grid; grid-template-columns: 240px 1fr; min-height: 100vh; }}
    .sidebar {{ background: #101b2d; border-right: 1px solid var(--line); padding: 18px; }}
    .sidebar h1 {{ margin: 0 0 6px; font-size: 22px; }}
    .meta {{ color: var(--muted); font-size: 14px; margin-bottom: 4px; }}
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
        self._send(200, render_page(payload), "text/html; charset=utf-8")

    def log_message(self, format, *args):
        return


class ReusableTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with ReusableTCPServer(("0.0.0.0", PORTAL_PORT), Handler) as httpd:
        httpd.serve_forever()
