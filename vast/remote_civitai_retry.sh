#!/usr/bin/env bash
set -euo pipefail

TOOL_DIR="${TOOL_DIR:-/workspace/minikrea2-tool}"
MODELS_DIR="${MODELS_DIR:-/workspace/ComfyUI/models/loras}"
LOG_DIR="${LOG_DIR:-$TOOL_DIR/runtime/logs}"

mkdir -p "$LOG_DIR" "$MODELS_DIR"

if [[ -f /proc/1/environ ]]; then
  eval "$(tr '\0' '\n' </proc/1/environ | grep -E '^(CIVITAI_API_KEY|CIVITAI_TOKEN|CIVITAI_BASE_URL)=' | sed 's/^/export /')"
fi

echo "CIVITAI_BASE_URL=${CIVITAI_BASE_URL:-}"
echo "CIVITAI_API_KEY=${CIVITAI_API_KEY:+set}"
echo "CIVITAI_TOKEN=${CIVITAI_TOKEN:+set}"

pkill -f "$TOOL_DIR/download_civitai.py 3268303" || true
pkill -f "$TOOL_DIR/download_civitai.py 3266628" || true
pkill -f "$TOOL_DIR/download_civitai.py 3252213" || true

nohup python3 "$TOOL_DIR/download_civitai.py" 3268303 "$MODELS_DIR" >"$LOG_DIR/civitai_hmnsfw.log" 2>&1 </dev/null &
echo "hmnsfw:$!"
nohup python3 "$TOOL_DIR/download_civitai.py" 3266628 "$MODELS_DIR" >"$LOG_DIR/civitai_mystic.log" 2>&1 </dev/null &
echo "mystic:$!"
nohup python3 "$TOOL_DIR/download_civitai.py" 3252213 "$MODELS_DIR" >"$LOG_DIR/civitai_hmpussy.log" 2>&1 </dev/null &
echo "hmpussy:$!"

sleep 4
for file in "$LOG_DIR"/civitai_hmnsfw.log "$LOG_DIR"/civitai_mystic.log "$LOG_DIR"/civitai_hmpussy.log; do
  echo "--- $file"
  sed -n '1,40p' "$file" || true
done
