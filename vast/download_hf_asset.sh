#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <repo_id> <repo_file> <dest_dir> [dest_name]" >&2
  exit 2
fi

REPO_ID="$1"
REPO_FILE="$2"
DEST_DIR="$3"
DEST_NAME="${4:-$(basename "$REPO_FILE")}"
TMP_DIR="${HF_TMP_DIR:-/tmp/hf-downloads}"

mkdir -p "$DEST_DIR" "$TMP_DIR"

if command -v hf >/dev/null 2>&1; then
  hf download "$REPO_ID" "$REPO_FILE" \
    --local-dir "$TMP_DIR/$REPO_ID" \
    --local-dir-use-symlinks False >/dev/null
elif command -v huggingface-cli >/dev/null 2>&1; then
  huggingface-cli download "$REPO_ID" "$REPO_FILE" \
    --local-dir "$TMP_DIR/$REPO_ID" \
    --local-dir-use-symlinks False >/dev/null
else
  python - "$REPO_ID" "$REPO_FILE" "$TMP_DIR/$REPO_ID" <<'PY'
import os
import sys
from huggingface_hub import hf_hub_download

repo_id, repo_file, local_dir = sys.argv[1:4]
token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
hf_hub_download(
    repo_id=repo_id,
    filename=repo_file,
    local_dir=local_dir,
    local_dir_use_symlinks=False,
    token=token,
)
PY
fi

SRC_PATH="$TMP_DIR/$REPO_ID/$REPO_FILE"
if [[ ! -f "$SRC_PATH" ]]; then
  echo "missing downloaded file: $SRC_PATH" >&2
  exit 1
fi

mv -f "$SRC_PATH" "$DEST_DIR/$DEST_NAME"
echo "$DEST_DIR/$DEST_NAME"
