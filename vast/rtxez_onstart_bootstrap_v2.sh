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
import shutil
import sys
from huggingface_hub import hf_hub_download

repo_id, repo_file, dest_dir, dest_name = sys.argv[1:5]
token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
tmp_path = hf_hub_download(
    repo_id=repo_id,
    filename=repo_file,
    token=token,
)
dest_path = os.path.join(dest_dir, dest_name)
os.makedirs(dest_dir, exist_ok=True)
shutil.copy2(tmp_path, dest_path)
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
        "--dir",
        str(dest_path.parent),
        "--out",
        dest_path.name,
        "--header",
        f"Authorization: Bearer {token}",
        download_url,
    ]
    subprocess.run(cmd, check=True)
else:
    with session.get(download_url, stream=True, timeout=60) as response:
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
}

download_models() {
  : > "$MODEL_LOG"
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
  hf_download "Kijai/MiniMax-H3-TAE" "taeh3.safetensors" "$COMFYUI_DIR/models/vae" >>"$MODEL_LOG" 2>&1 &
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
}

log "start $(date --iso-8601=seconds)"
log "workspace=$(readlink -f /workspace || echo /workspace)"
log "comfyui_dir=$COMFYUI_DIR"
if [[ -n "${HF_TOKEN:-}" ]]; then log "HF token detected"; else log "HF token missing"; fi
if [[ -n "${CIVITAI_API_KEY:-${CIVITAI_TOKEN:-}}" ]]; then log "Civitai token detected"; else log "Civitai token missing"; fi

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

log "done $(date --iso-8601=seconds)"
