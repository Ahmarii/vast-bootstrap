#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${LOG_DIR:-/workspace/minikrea2-tool/runtime/logs}"
STATE_DIR="${STATE_DIR:-/workspace/minikrea2-tool/runtime/state}"
SETUP_DIR="${SETUP_DIR:-/workspace/minikrea2-tool}"
COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$SETUP_DIR" "$COMFYUI_DIR"

exec > >(tee -a "$LOG_DIR/provision_rtxez_base.log") 2>&1

echo "[provision] start $(date --iso-8601=seconds)"

if [[ ! -d "$COMFYUI_DIR/.git" ]]; then
  echo "[provision] expected ComfyUI at $COMFYUI_DIR but it does not look initialized"
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  aria2 \
  git \
  curl \
  jq \
  unzip \
  ca-certificates

python3 -m pip install --upgrade pip setuptools wheel

if [[ -n "${HF_TOKEN:-}" ]]; then
  export HUGGINGFACE_HUB_TOKEN="$HF_TOKEN"
  export HF_HUB_ENABLE_HF_TRANSFER=1
  echo "[provision] HF token detected"
else
  echo "[provision] HF token missing"
fi

if [[ -n "${CIVITAI_API_KEY:-${CIVITAI_TOKEN:-}}" ]]; then
  echo "[provision] Civitai token detected"
else
  echo "[provision] Civitai token missing"
fi

cat > /workspace/minikrea2-tool/runtime/check_env.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "HF_TOKEN=${HF_TOKEN:+set}"
echo "CIVITAI_API_KEY=${CIVITAI_API_KEY:+set}"
echo "CIVITAI_TOKEN=${CIVITAI_TOKEN:+set}"
echo "COMFYUI_DIR=${COMFYUI_DIR:-/workspace/ComfyUI}"
EOF
chmod +x /workspace/minikrea2-tool/runtime/check_env.sh

echo "[provision] done $(date --iso-8601=seconds)"
