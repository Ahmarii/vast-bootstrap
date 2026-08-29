#!/usr/bin/env python3
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

import requests


def build_browser_headers(token=None):
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/140.0.0.0 Safari/537.36"
        ),
        "Accept": "*/*",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


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
        "--retry-wait=3",
        "--max-tries=5",
        "--dir",
        str(destination.parent),
        "--out",
        destination.name,
        "--header",
        f"Authorization: Bearer {token}",
        "--header",
        "User-Agent: Mozilla/5.0",
        "--header",
        "Accept: */*",
        url,
    ]
    subprocess.run(cmd, check=True)


def requests_download(session, url, destination, token):
    tmp = destination.with_suffix(destination.suffix + ".part")
    headers = build_browser_headers(token)
    resume_at = tmp.stat().st_size if tmp.exists() else 0
    if resume_at:
        headers["Range"] = f"bytes={resume_at}-"

    with session.get(url, headers=headers, stream=True, timeout=120) as response:
        if response.status_code in (401, 403):
            signed_url = resolve_download_url(url, token)
            response.close()
            headers = build_browser_headers()
            if resume_at:
                headers["Range"] = f"bytes={resume_at}-"
            response = requests.get(signed_url, headers=headers, stream=True, timeout=120)
        if response.status_code == 416:
            tmp.rename(destination)
            return
        if response.status_code == 200 and resume_at:
            tmp.unlink(missing_ok=True)
            resume_at = 0
        response.raise_for_status()
        mode = "ab" if resume_at else "wb"
        with open(tmp, mode) as handle:
            for chunk in response.iter_content(chunk_size=16 * 1024 * 1024):
                if chunk:
                    handle.write(chunk)
    tmp.rename(destination)


def resolve_download_url(download_url, token):
    response = requests.get(
        download_url,
        headers=build_browser_headers(token),
        allow_redirects=False,
        timeout=60,
    )
    response.raise_for_status()
    if response.is_redirect or response.is_permanent_redirect:
        location = response.headers.get("Location")
        if not location:
            raise RuntimeError("Download URL redirected without a Location header.")
        return location
    return download_url


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
        try:
            aria2_download(download_url, destination, token)
        except subprocess.CalledProcessError as exc:
            print(f"warning: aria2c failed with exit code {exc.returncode}, falling back to streamed download", file=sys.stderr)
            requests_download(session, download_url, destination, token)
    else:
        requests_download(session, download_url, destination, token)

    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
