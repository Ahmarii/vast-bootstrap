#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_RAW_BASE="${BOOTSTRAP_RAW_BASE:-https://raw.githubusercontent.com/Ahmarii/vast-bootstrap/main/vast}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
COMFYUI_DIR="${COMFYUI_DIR:-$WORKSPACE_DIR/ComfyUI}"
TOOL_DIR="${TOOL_DIR:-$WORKSPACE_DIR/minikrea2-tool}"
VAST_DIR="$TOOL_DIR/vast"
RUNTIME_DIR="$TOOL_DIR/runtime"
LOG_DIR="$RUNTIME_DIR/logs"
STATE_DIR="$RUNTIME_DIR/state"
BIN_DIR="$TOOL_DIR/bin"
LOG_FILE="$LOG_DIR/provision_rtxez_base.log"

mkdir -p "$COMFYUI_DIR" "$VAST_DIR" "$RUNTIME_DIR" "$LOG_DIR" "$STATE_DIR" "$BIN_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[provision] %s\n' "$*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_python() {
  if [[ -x /venv/main/bin/python ]]; then
    printf '%s\n' /venv/main/bin/python
  elif have_cmd python3; then
    command -v python3
  elif have_cmd python; then
    command -v python
  else
    return 1
  fi
}

write_helper() {
  local name="$1"
  local target="$VAST_DIR/$name"
  curl -fsSL "$BOOTSTRAP_RAW_BASE/$name" -o "$target"
  chmod +x "$target" || true
}

write_runtime_helper() {
  cat > "$RUNTIME_DIR/check_env.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "HF_TOKEN=${HF_TOKEN:+set}"
echo "CIVITAI_API_KEY=${CIVITAI_API_KEY:+set}"
echo "CIVITAI_TOKEN=${CIVITAI_TOKEN:+set}"
echo "COMFYUI_DIR=${COMFYUI_DIR:-/workspace/ComfyUI}"
echo "TOOL_DIR=${TOOL_DIR:-/workspace/minikrea2-tool}"
EOF
  chmod +x "$RUNTIME_DIR/check_env.sh"
}

log "start $(date --iso-8601=seconds)"

if [[ ! -d "$COMFYUI_DIR/.git" ]]; then
  log "warning: expected ComfyUI at $COMFYUI_DIR but it does not look like a git checkout"
fi

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

PY_BIN="$(detect_python)"
ln -sf "$PY_BIN" /usr/local/bin/python || true
ln -sf "$PY_BIN" /usr/local/bin/python3 || true

"$PY_BIN" -m pip install --upgrade pip setuptools wheel
"$PY_BIN" -m pip install --upgrade "huggingface_hub[hf_transfer]" requests

if [[ -n "${HF_TOKEN:-}" ]]; then
  export HUGGINGFACE_HUB_TOKEN="$HF_TOKEN"
  export HF_HUB_ENABLE_HF_TRANSFER=1
  log "HF token detected"
else
  log "HF token missing"
fi

if [[ -n "${CIVITAI_API_KEY:-${CIVITAI_TOKEN:-}}" ]]; then
  log "Civitai token detected"
else
  log "Civitai token missing"
fi

write_helper "download_hf_asset.sh"
write_helper "download_civitai_version.py"
write_helper "bootstrap_rtxez_remote.sh"
write_runtime_helper

export WORKSPACE_DIR COMFYUI_DIR TOOL_DIR VAST_DIR RUNTIME_DIR LOG_DIR STATE_DIR BIN_DIR PY_BIN

bash "$VAST_DIR/bootstrap_rtxez_remote.sh"

log "done $(date --iso-8601=seconds)"
