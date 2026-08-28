# RTX-EZ Bootstrap

This is the current first-boot bootstrap path for the Vast template `MINIKrea2 RTX-EZ Provisioned`.

## Hosted entrypoint

- Raw script: `https://raw.githubusercontent.com/Ahmarii/vast-bootstrap/main/vast/provision_rtxez_base.sh`

## What it does

1. Installs base tools:
   - `aria2`
   - `curl`
   - `git`
   - `jq`
   - `ffmpeg`
   - `python3`
2. Ensures `python` exists even on images that only expose `python3`.
3. Installs Python downloader dependencies:
   - `huggingface_hub[hf_transfer]`
   - `requests`
4. Pulls helper scripts from the GitHub raw repo into `/workspace/minikrea2-tool/vast`.
5. Runs the RTX-EZ bootstrap worker.
6. In parallel, the worker:
   - clones or updates required custom nodes
   - installs node requirements
   - installs `comfyui-manager`, `kornia==0.8.2`, and `nvidia-vfx`
   - forces a torchvision wheel that matches the installed torch CUDA line
   - downloads the main MiniMax H3 RTX-EZ models concurrently
   - downloads the smaller VAEs and LoRAs concurrently
7. Attempts to restart `comfyui` and `api-wrapper` if `supervisorctl` exposes them.

## Node packs installed

- `ComfyUI-Manager`
- `ComfyUI-INT8-Fast`
- `ComfyUI-SolAttn_triton`
- `ComfyUI-KJNodes`
- `rgthree-comfy`
- `ComfyUI-Easy-Use`
- `ComfyUI-VideoHelperSuite`
- `Nvidia_RTX_Nodes_ComfyUI`
- `ComfyUI-Image-Saver`

## Model groups

Large concurrent downloads:

- `minimax_h3_fl2va_pruned_int8_convrot.safetensors`
- `minimax_h3_ref2va_pruned_int8_convrot.safetensors`
- `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`

Small concurrent downloads:

- `minimax_h3_video_vae_fp16.safetensors`
- `minimax_h3_audio_vae_fp32.safetensors`
- `minimax_h3_fl2v_lightx2v_turbo_4step_v0.1_comfy.safetensors`
- `taeh3.safetensors`
- `HMNSFW_AIO_Sex_LoRA.safetensors`
- `MysticXXX_MMH3-V4.safetensors`
- `HM_Pussy_Pussyanus_MMH3.safetensors`
- `H3_Vagina_MMH3.safetensors`

## Remote status check

After provisioning on Vast, run:

```bash
/workspace/minikrea2-tool/check_rtxez_bootstrap.sh
```

Logs:

- `/workspace/minikrea2-tool/runtime/logs/provision_rtxez_base.log`
- `/workspace/minikrea2-tool/runtime/logs/rtxez_nodes.log`
- `/workspace/minikrea2-tool/runtime/logs/rtxez_models.log`

## Known tradeoff

The Civitai helper chooses the best safetensors file automatically when a version exposes multiple files and no explicit file name is provided. That is fine for the current LoRA list, but not safe for random checkpoint pages with several variants.
