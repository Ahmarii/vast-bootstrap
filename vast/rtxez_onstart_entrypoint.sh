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

if [[ ! -e /workspace && -d /opt/workspace-internal ]]; then
  ln -sfn /opt/workspace-internal /workspace
fi

mkdir -p /workspace "$TOOL_DIR/vast" "$STATE_DIR" "$LOG_DIR"

if [[ ! -x "$PY_BIN" ]]; then
  PY_BIN="$(command -v python3 || command -v python)"
fi

cat > "$STATUS_JSON" <<EOF
{"phase":"starting","detail":"Portal started. Waiting for bootstrap worker to begin.","updated_at":"$(date --iso-8601=seconds)","comfyui_dir":"/workspace/ComfyUI"}
EOF

curl -fsSL "$PORTAL_SOURCE_URL" -o "$PORTAL_SCRIPT"
chmod +x "$PORTAL_SCRIPT"

if ! pgrep -f "$PORTAL_SCRIPT" >/dev/null 2>&1; then
  nohup "$PY_BIN" "$PORTAL_SCRIPT" >"$LOG_DIR/status_portal.log" 2>&1 </dev/null &
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
