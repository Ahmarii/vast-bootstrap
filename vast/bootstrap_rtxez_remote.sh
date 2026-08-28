#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
COMFYUI_DIR="${COMFYUI_DIR:-$WORKSPACE_DIR/ComfyUI}"
TOOL_DIR="${TOOL_DIR:-$WORKSPACE_DIR/minikrea2-tool}"
VAST_DIR="${VAST_DIR:-$TOOL_DIR/vast}"
RUNTIME_DIR="${RUNTIME_DIR:-$TOOL_DIR/runtime}"
LOG_DIR="${LOG_DIR:-$RUNTIME_DIR/logs}"
STATE_DIR="${STATE_DIR:-$RUNTIME_DIR/state}"
PY_BIN="${PY_BIN:-python}"

NODE_LOG="$LOG_DIR/rtxez_nodes.log"
MODEL_LOG="$LOG_DIR/rtxez_models.log"
STATUS_SCRIPT="$TOOL_DIR/check_rtxez_bootstrap.sh"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$COMFYUI_DIR/custom_nodes" \
  "$COMFYUI_DIR/models/diffusion_models" \
  "$COMFYUI_DIR/models/text_encoders" \
  "$COMFYUI_DIR/models/vae" \
  "$COMFYUI_DIR/models/loras"

log_node() {
  printf '[rtx-ez-nodes] %s\n' "$*" | tee -a "$NODE_LOG"
}

log_model() {
  printf '[rtx-ez-models] %s\n' "$*" | tee -a "$MODEL_LOG"
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

write_status_script() {
  cat > "$STATUS_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="${LOG_DIR:-/workspace/minikrea2-tool/runtime/logs}"
echo "== node log tail =="
tail -n 20 "$LOG_DIR/rtxez_nodes.log" 2>/dev/null || true
echo
echo "== model log tail =="
tail -n 20 "$LOG_DIR/rtxez_models.log" 2>/dev/null || true
echo
echo "== biggest model files =="
find /workspace/ComfyUI/models -type f 2>/dev/null | xargs -r du -h | sort -h | tail -n 20
EOF
  chmod +x "$STATUS_SCRIPT"
}

restart_service_if_present() {
  local service_name="$1"
  if command -v supervisorctl >/dev/null 2>&1; then
    if supervisorctl status "$service_name" >/dev/null 2>&1; then
      supervisorctl restart "$service_name" || true
    fi
  fi
}

fix_torchvision_if_needed() {
  local torch_cuda
  local torch_version
  local tv_version
  local cu_tag
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
if major != 2:
    print("")
else:
    print(f"0.{minor + 15}.0")
PY
)"
  if [[ -z "$torch_cuda" || -z "$tv_version" ]]; then
    return 0
  fi
  cu_tag="cu$torch_cuda"
  log_node "forcing torchvision==$tv_version on $cu_tag to match torch==$torch_version"
  "$PY_BIN" -m pip install --force-reinstall --no-deps \
    --index-url "https://download.pytorch.org/whl/$cu_tag" \
    "torchvision==$tv_version"
}

install_nodes() {
  : > "$NODE_LOG"
  log_node "start $(date --iso-8601=seconds)"
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

  fix_torchvision_if_needed
  log_node "done $(date --iso-8601=seconds)"
}

run_hf() {
  local repo="$1"
  local repo_file="$2"
  local dest_dir="$3"
  local dest_name="${4:-}"
  if [[ -n "$dest_name" ]]; then
    bash "$VAST_DIR/download_hf_asset.sh" "$repo" "$repo_file" "$dest_dir" "$dest_name" >>"$MODEL_LOG" 2>&1
  else
    bash "$VAST_DIR/download_hf_asset.sh" "$repo" "$repo_file" "$dest_dir" >>"$MODEL_LOG" 2>&1
  fi
}

run_civitai() {
  local version_id="$1"
  local dest_dir="$2"
  local dest_name="${3:-}"
  if [[ -n "$dest_name" ]]; then
    "$PY_BIN" "$VAST_DIR/download_civitai_version.py" \
      --version-id "$version_id" \
      --dest-dir "$dest_dir" \
      --dest-name "$dest_name" >>"$MODEL_LOG" 2>&1
  else
    "$PY_BIN" "$VAST_DIR/download_civitai_version.py" \
      --version-id "$version_id" \
      --dest-dir "$dest_dir" >>"$MODEL_LOG" 2>&1
  fi
}

wait_jobs() {
  local failed=0
  local pid
  for pid in "$@"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done
  return "$failed"
}

download_models() {
  local pids=()
  : > "$MODEL_LOG"
  log_model "start $(date --iso-8601=seconds)"

  log_model "queue hf h3 fl2va"
  run_hf "Comfy-Org/MiniMax-H3" "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" "$COMFYUI_DIR/models/diffusion_models" &
  pids+=("$!")

  log_model "queue hf h3 ref2va"
  run_hf "Comfy-Org/MiniMax-H3" "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" "$COMFYUI_DIR/models/diffusion_models" &
  pids+=("$!")

  log_model "queue hf h3 text encoder"
  run_hf "Comfy-Org/MiniMax-H3" "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" "$COMFYUI_DIR/models/text_encoders" &
  pids+=("$!")

  if ! wait_jobs "${pids[@]}"; then
    log_model "one or more large HF downloads failed"
    return 1
  fi

  pids=()
  log_model "queue hf video vae"
  run_hf "Comfy-Org/MiniMax-H3" "vae/minimax_h3_video_vae_fp16.safetensors" "$COMFYUI_DIR/models/vae" &
  pids+=("$!")

  log_model "queue hf audio vae"
  run_hf "Comfy-Org/MiniMax-H3" "vae/minimax_h3_audio_vae_fp32.safetensors" "$COMFYUI_DIR/models/vae" &
  pids+=("$!")

  log_model "queue hf lightx turbo lora"
  run_hf "Kijai/MiniMax-H3_comfy" "loras/minimax_h3_fl2v_lightx2v_turbo_4step_v0.1_comfy.safetensors" "$COMFYUI_DIR/models/loras" &
  pids+=("$!")

  log_model "queue hf tiny vae"
  run_hf "Kijai/MiniMax-H3-TAE" "taeh3.safetensors" "$COMFYUI_DIR/models/vae" &
  pids+=("$!")

  log_model "queue civitai hmnsfw aio sex lora"
  run_civitai "3268303" "$COMFYUI_DIR/models/loras" "HMNSFW_AIO_Sex_LoRA.safetensors" &
  pids+=("$!")

  log_model "queue civitai mystic xxx v4"
  run_civitai "3266628" "$COMFYUI_DIR/models/loras" "MysticXXX_MMH3-V4.safetensors" &
  pids+=("$!")

  log_model "queue civitai hmpussy pussyanus"
  run_civitai "3252213" "$COMFYUI_DIR/models/loras" "HM_Pussy_Pussyanus_MMH3.safetensors" &
  pids+=("$!")

  log_model "queue civitai h3 vagina"
  run_civitai "3200540" "$COMFYUI_DIR/models/loras" "H3_Vagina_MMH3.safetensors" &
  pids+=("$!")

  if ! wait_jobs "${pids[@]}"; then
    log_model "one or more small downloads failed"
    return 1
  fi

  log_model "done $(date --iso-8601=seconds)"
}

write_status_script

install_nodes &
NODE_PID="$!"
download_models &
MODEL_PID="$!"

wait_jobs "$NODE_PID" "$MODEL_PID"

restart_service_if_present comfyui
restart_service_if_present api-wrapper
