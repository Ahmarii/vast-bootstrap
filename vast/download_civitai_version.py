#!/usr/bin/env python3
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

import requests


def choose_file(version_data, file_name):
    files = version_data.get("files") or []
    if not files:
        raise RuntimeError(f"Version {version_data.get('id')} has no files.")

    if file_name:
        for item in files:
            if item.get("name") == file_name:
                return item
        raise RuntimeError(f"File name {file_name!r} was not found in version {version_data.get('id')}.")

    preferred = []
    for item in files:
        name = (item.get("name") or "").lower()
        item_type = (item.get("type") or "").lower()
        if name.endswith(".safetensors"):
            preferred.append((2, item))
        elif name.endswith(".gguf"):
            preferred.append((1, item))
        elif item_type == "model":
            preferred.append((0, item))
        else:
            preferred.append((-1, item))

    preferred.sort(key=lambda pair: (pair[0], pair[1].get("sizeKB", 0)), reverse=True)
    return preferred[0][1]


def aria2_download(url, destination, token):
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
        str(destination.parent),
        "--out",
        destination.name,
        "--header",
        f"Authorization: Bearer {token}",
        url,
    ]
    subprocess.run(cmd, check=True)


def requests_download(session, url, destination):
    with session.get(url, stream=True, timeout=60) as response:
        response.raise_for_status()
        with open(destination, "wb") as handle:
            for chunk in response.iter_content(chunk_size=16 * 1024 * 1024):
                if chunk:
                    handle.write(chunk)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version-id", required=True, type=int)
    parser.add_argument("--dest-dir", required=True)
    parser.add_argument("--file-name")
    parser.add_argument("--dest-name")
    parser.add_argument("--base-url", default=os.environ.get("CIVITAI_BASE_URL", "https://civitai.red"))
    args = parser.parse_args()

    token = os.environ.get("CIVITAI_API_KEY") or os.environ.get("CIVITAI_TOKEN")
    if not token:
        raise SystemExit("CIVITAI_API_KEY or CIVITAI_TOKEN is required.")

    session = requests.Session()
    session.headers.update({"Authorization": f"Bearer {token}"})
    version_url = f"{args.base_url.rstrip('/')}/api/v1/model-versions/{args.version_id}"
    version_response = session.get(version_url, timeout=30)
    version_response.raise_for_status()
    version_data = version_response.json()

    selected = choose_file(version_data, args.file_name)
    download_url = selected.get("downloadUrl") or f"{args.base_url.rstrip('/')}/api/download/models/{args.version_id}"
    dest_dir = Path(args.dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest_name = args.dest_name or selected["name"]
    destination = dest_dir / dest_name

    if shutil.which("aria2c"):
        aria2_download(download_url, destination, token)
    else:
        requests_download(session, download_url, destination)

    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
