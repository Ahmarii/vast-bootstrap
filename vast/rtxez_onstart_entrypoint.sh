#!/usr/bin/env bash
set -euo pipefail

RAW_BASE="${BOOTSTRAP_RAW_BASE:-https://raw.githubusercontent.com/Ahmarii/vast-bootstrap/main/vast}"
TOOL_DIR="/workspace/minikrea2-tool"
RUNTIME_DIR="$TOOL_DIR/runtime"
STATE_DIR="$RUNTIME_DIR/state"
LOG_DIR="$RUNTIME_DIR/logs"
STATUS_JSON="$STATE_DIR/status.json"
PORTAL_SCRIPT="$TOOL_DIR/status_portal.py"
BOOTSTRAP_SCRIPT="$TOOL_DIR/vast/rtxez_onstart_bootstrap_v2.sh"
PORTAL_SOURCE_URL="${PORTAL_SOURCE_URL:-$RAW_BASE/instant_status_portal.py}"
BOOTSTRAP_URL="${BOOTSTRAP_URL:-$RAW_BASE/rtxez_onstart_bootstrap_v2.sh}"
PY_BIN="/venv/main/bin/python"
ENV_FILE="/workspace/.env"

if [[ ! -e /workspace && -d /opt/workspace-internal ]]; then
  ln -sfn /opt/workspace-internal /workspace
fi

mkdir -p /workspace "$TOOL_DIR/vast" "$STATE_DIR" "$LOG_DIR"

if [[ ! -x "$PY_BIN" ]]; then
  PY_BIN="$(command -v python3 || command -v python)"
fi

persist_runtime_env() {
  "$PY_BIN" - "$ENV_FILE" <<'PY'
import os
import shlex
import sys
from pathlib import Path

env_file = Path(sys.argv[1])
keys = [
    "HF_TOKEN",
    "HUGGINGFACE_HUB_TOKEN",
    "CIVITAI_API_KEY",
    "CIVITAI_TOKEN",
    "CIVITAI_BASE_URL",
    "HF_XET_HIGH_PERFORMANCE",
    "ARIA2_CONNECTIONS",
    "ARIA2_SPLIT",
    "ARIA2_MIN_SPLIT_SIZE",
    "COMFYUI_DIR",
    "VAGASSIST_LORA_URL",
    "H3_RTX_EZ_TEXT_ENCODER_REPO",
    "H3_RTX_EZ_TEXT_ENCODER_FILE",
    "H3_RTX_EZ_LIGHTX_REPO",
    "H3_RTX_EZ_LIGHTX_FILE",
    "H3_RTX_EZ_LARRY_REPO",
    "H3_RTX_EZ_LARRY_FILE",
]

existing = {}
lines = []
if env_file.exists():
    lines = env_file.read_text(encoding="utf-8", errors="ignore").splitlines()
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        existing[key] = value

for key in keys:
    value = os.environ.get(key)
    if value:
        existing[key] = shlex.quote(value)

out_lines = []
seen = set()
for line in lines:
    stripped = line.strip()
    if stripped and not stripped.startswith("#") and "=" in stripped:
        key = stripped.split("=", 1)[0]
        if key in existing:
            out_lines.append(f"{key}={existing[key]}")
            seen.add(key)
            continue
    out_lines.append(line)

for key in keys:
    if key in existing and key not in seen:
        out_lines.append(f"{key}={existing[key]}")

env_file.write_text("\n".join(out_lines).rstrip() + "\n", encoding="utf-8")
PY
}

persist_runtime_env

start_portal_instance() {
  local port="$1"
  local log_name="$2"
  if ss -ltn 2>/dev/null | grep -q ":${port} "; then
    return
  fi
  nohup env OPEN_BUTTON_PORT="$port" "$PY_BIN" "$PORTAL_SCRIPT" >"$LOG_DIR/${log_name}" 2>&1 </dev/null &
}

cat > "$STATUS_JSON" <<EOF
{"phase":"starting","detail":"Portal started. Waiting for bootstrap worker to begin.","updated_at":"$(date --iso-8601=seconds)","comfyui_dir":"/workspace/ComfyUI"}
EOF

curl -fsSL "$PORTAL_SOURCE_URL" -o "$PORTAL_SCRIPT"
chmod +x "$PORTAL_SCRIPT"

start_portal_instance "${OPEN_BUTTON_PORT:-1111}" "status_portal.log"
if [[ -n "${VAST_TCP_PORT_11111:-}" && "${OPEN_BUTTON_PORT:-1111}" != "11111" ]]; then
  start_portal_instance "11111" "status_portal_11111.log"
fi

cat > "$STATUS_JSON" <<EOF
{"phase":"fetching_bootstrap","detail":"Portal is live. Fetching bootstrap worker.","updated_at":"$(date --iso-8601=seconds)","comfyui_dir":"/workspace/ComfyUI"}
EOF

curl -fsSL "$BOOTSTRAP_URL" -o "$BOOTSTRAP_SCRIPT"
chmod +x "$BOOTSTRAP_SCRIPT"

cat > "$STATUS_JSON" <<EOF
{"phase":"launching_bootstrap","detail":"Portal is live. Bootstrap worker launched in background.","updated_at":"$(date --iso-8601=seconds)","comfyui_dir":"/workspace/ComfyUI"}
EOF

nohup bash "$BOOTSTRAP_SCRIPT" >"$LOG_DIR/onstart_launcher.log" 2>&1 </dev/null &
