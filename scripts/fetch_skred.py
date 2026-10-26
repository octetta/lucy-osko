#!/usr/bin/env python3
"""
Fetch Skred audio engine release assets (native library, headers, WASM runtime)
from GitHub Releases (octetta/pulp) based on the SKRED_VERSION file.
"""

import argparse
import io
import os
import platform
import shutil
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_VERSION_FILE = REPO_ROOT / "SKRED_VERSION"
DEFAULT_GITHUB_REPO = "octetta/pulp"


def detect_platform_slug():
    system = platform.system().lower()
    machine = platform.machine().lower()

    if system == "linux":
        if machine in ("x86_64", "amd64"):
            return "linux-x86_64", ".tar.gz"
        elif machine in ("aarch64", "arm64"):
            return "linux-aarch64", ".tar.gz"
        elif "arm" in machine:
            return "linux-armhf", ".tar.gz"
        else:
            raise RuntimeError(f"Unsupported Linux machine architecture: {machine}")
    elif system == "darwin":
        return "macos-universal", ".tar.gz"
    elif system in ("windows", "win32"):
        return "windows-x86_64", ".zip"
    else:
        raise RuntimeError(f"Unsupported operating system: {system}")


def download_file(url: str) -> bytes:
    print(f"[LUCY+OSKO] Downloading: {url}")
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "LUCY+OSKO-Build/1.0 (https://github.com/octetta/pulp)"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            if resp.status != 200:
                raise RuntimeError(f"HTTP {resp.status} fetching {url}")
            return resp.read()
    except Exception as exc:
        raise RuntimeError(f"Failed to download {url}: {exc}") from exc


def extract_native_assets(archive_bytes: bytes, is_zip: bool, dest_root: Path):
    lib_dir = dest_root / "host" / "vendor" / "skred" / "lib"
    inc_dir = dest_root / "host" / "vendor" / "skred" / "include" / "skred"
    lib_dir.mkdir(parents=True, exist_ok=True)
    inc_dir.mkdir(parents=True, exist_ok=True)

    if not is_zip:
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:gz") as tar:
            for member in tar.getmembers():
                if not member.isfile():
                    continue
                path_parts = Path(member.name).parts
                if member.name.endswith("libapi.a"):
                    dest_path = lib_dir / "libapi.a"
                    with open(dest_path, "wb") as f:
                        f.write(tar.extractfile(member).read())
                    print(f"  -> Extracted {dest_path.relative_to(dest_root)}")
                elif "include" in path_parts and "skred" in path_parts and member.name.endswith(".h"):
                    filename = Path(member.name).name
                    dest_path = inc_dir / filename
                    with open(dest_path, "wb") as f:
                        f.write(tar.extractfile(member).read())
                    print(f"  -> Extracted {dest_path.relative_to(dest_root)}")
    else:
        with zipfile.ZipFile(io.BytesIO(archive_bytes)) as z:
            for name in z.namelist():
                path_parts = Path(name).parts
                if name.endswith("libapi.a"):
                    dest_path = lib_dir / "libapi.a"
                    with open(dest_path, "wb") as f:
                        f.write(z.read(name))
                    print(f"  -> Extracted {dest_path.relative_to(dest_root)}")
                elif "include" in path_parts and "skred" in path_parts and name.endswith(".h"):
                    filename = Path(name).name
                    dest_path = inc_dir / filename
                    with open(dest_path, "wb") as f:
                        f.write(z.read(name))
                    print(f"  -> Extracted {dest_path.relative_to(dest_root)}")


def extract_wasm_assets(archive_bytes: bytes, dest_root: Path):
    dist_dir = dest_root / "dist"
    dist_dir.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as z:
        for name in z.namelist():
            filename = Path(name).name
            if filename in ("skred_api.js", "skred_api.wasm"):
                dest_path = dist_dir / filename
                with open(dest_path, "wb") as f:
                    f.write(z.read(name))
                print(f"  -> Extracted {dest_path.relative_to(dest_root)}")


def main():
    parser = argparse.ArgumentParser(
        description="Fetch Skred assets from GitHub Releases based on SKRED_VERSION."
    )
    parser.add_argument(
        "--version",
        help="Skred version (e.g. 0.79.1). Defaults to content of SKRED_VERSION file.",
    )
    parser.add_argument(
        "--repo",
        default=DEFAULT_GITHUB_REPO,
        help="GitHub repo slug (default: octetta/pulp).",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Force re-download even if version stamp matches.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check if assets are present and up to date without downloading.",
    )
    args = parser.parse_args()

    if args.version:
        version = args.version.strip()
    elif DEFAULT_VERSION_FILE.exists():
        version = DEFAULT_VERSION_FILE.read_text().strip()
    else:
        sys.exit(f"Error: {DEFAULT_VERSION_FILE} not found and no --version supplied.")

    platform_slug, ext = detect_platform_slug()
    stamp_file = REPO_ROOT / "host" / "vendor" / "skred" / ".skred_version"
    lib_file = REPO_ROOT / "host" / "vendor" / "skred" / "lib" / "libapi.a"
    wasm_file = REPO_ROOT / "dist" / "skred_api.wasm"
    js_file = REPO_ROOT / "dist" / "skred_api.js"

    current_stamp = stamp_file.read_text().strip() if stamp_file.exists() else ""
    expected_stamp = f"{version}:{platform_slug}"

    if args.check:
        if (
            current_stamp == expected_stamp
            and lib_file.exists()
            and wasm_file.exists()
            and js_file.exists()
        ):
            print(f"[LUCY+OSKO] Skred {version} assets are already up-to-date.")
            sys.exit(0)
        else:
            print(f"[LUCY+OSKO] Skred {version} assets need to be fetched.")
            sys.exit(1)

    if (
        not args.force
        and current_stamp == expected_stamp
        and lib_file.exists()
        and wasm_file.exists()
        and js_file.exists()
    ):
        print(f"[LUCY+OSKO] Skred {version} assets are already up-to-date ({expected_stamp}).")
        return

    print(f"[LUCY+OSKO] Fetching Skred v{version} assets for {platform_slug} from {args.repo}...")

    # 1. Fetch & extract native assets
    native_archive_name = f"skred-{version}-maxed-{platform_slug}{ext}"
    native_url = f"https://github.com/{args.repo}/releases/download/v{version}/{native_archive_name}"
    native_bytes = download_file(native_url)
    extract_native_assets(native_bytes, is_zip=(ext == ".zip"), dest_root=REPO_ROOT)

    # 2. Fetch & extract WASM assets
    wasm_archive_name = f"skred-{version}-maxed-wasm.zip"
    wasm_url = f"https://github.com/{args.repo}/releases/download/v{version}/{wasm_archive_name}"
    wasm_bytes = download_file(wasm_url)
    extract_wasm_assets(wasm_bytes, dest_root=REPO_ROOT)

    # 3. Update stamp
    stamp_file.parent.mkdir(parents=True, exist_ok=True)
    stamp_file.write_text(f"{expected_stamp}\n")
    print(f"[LUCY+OSKO] Successfully synchronized Skred v{version} assets!")


if __name__ == "__main__":
    main()
