#!/usr/bin/env python3
"""LLVM binary fetcher script for mc (ModC).

Downloads vendored clang-format, clang-tidy, and clangd binaries from LLVM
GitHub releases into vendor/tools/.
"""

import argparse
import json
import os
import platform
import shutil
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR_TOOLS = ROOT / "vendor" / "tools"
TOOLS = ["clang-format", "clang-tidy", "clangd"]


def find_matching_asset(version):
    system = platform.system().lower()
    machine = platform.machine().lower()

    is_arm = machine in ("arm64", "aarch64")
    is_x86 = machine in ("x86_64", "amd64")

    # Try known release tags for the given version
    tags_to_try = [
        f"llvmorg-{version}.1.8",
        f"llvmorg-{version}.1.7",
        f"llvmorg-{version}.1.6",
        f"llvmorg-{version}.1.0",
    ]

    for tag in tags_to_try:
        api_url = f"https://api.github.com/repos/llvm/llvm-project/releases/tags/{tag}"
        req = urllib.request.Request(
            api_url,
            headers={"User-Agent": "mc-fetch-tools/1.0", "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(req) as resp:
                rel = json.loads(resp.read().decode("utf-8"))
                for asset in rel.get("assets", []):
                    name = asset["name"].lower()
                    url = asset["browser_download_url"]

                    if not (name.startswith("clang+llvm-") or name.startswith("llvm-")):
                        continue
                    if not (name.endswith(".tar.xz") or name.endswith(".tar.gz") or name.endswith(".zip")):
                        continue

                    if system == "darwin":
                        if "apple" in name or "darwin" in name or "macos" in name:
                            if (is_arm and ("arm64" in name or "aarch64" in name)) or (is_x86 and ("x86_64" in name or "x64" in name)):
                                return tag, url, asset["name"]
                    elif system == "linux":
                        if "linux" in name:
                            if (is_arm and ("aarch64" in name or "arm64" in name)) or (is_x86 and ("x86_64" in name or "x64" in name)):
                                return tag, url, asset["name"]
                    elif system == "windows":
                        if "win" in name or "windows" in name:
                            if (is_arm and ("arm64" in name or "aarch64" in name)) or (is_x86 and ("x64" in name or "x86_64" in name)):
                                return tag, url, asset["name"]
        except Exception:
            continue

    # Fallback to direct URL construction
    arch = "aarch64" if is_arm else "x86_64"
    os_name = "apple-darwin" if system == "darwin" else ("windows-msvc" if system == "windows" else "linux-gnu")
    tag = f"llvmorg-{version}.1.0"
    ver = f"{version}.1.0"
    url = f"https://github.com/llvm/llvm-project/releases/download/{tag}/clang+llvm-{ver}-{arch}-{os_name}.tar.xz"
    return tag, url, f"clang+llvm-{ver}-{arch}-{os_name}.tar.xz"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", type=int, default=22, help="LLVM major version (default: 22)")
    parser.add_argument("--dry-run", action="store_true", help="Resolve release URL only without downloading")
    parser.add_argument("tools", nargs="*", help="Tools to fetch (default: all)")
    args = parser.parse_args()

    requested_tools = args.tools if args.tools else TOOLS
    for tool in requested_tools:
        if tool not in TOOLS:
            sys.exit(f"Unknown tool: {tool}. Allowed: {', '.join(TOOLS)}")

    tag, url, filename = find_matching_asset(args.version)

    print(f"Resolved LLVM release: {tag}")
    print(f"Asset: {filename}")
    print(f"Download URL: {url}")

    if args.dry_run:
        print("Dry run — not downloading.")
        return

    VENDOR_TOOLS.mkdir(parents=True, exist_ok=True)
    tar_path = VENDOR_TOOLS / filename

    print("Downloading archive...")
    req = urllib.request.Request(url, headers={"User-Agent": "mc-fetch-tools/1.0"})
    try:
        with urllib.request.urlopen(req) as resp, open(tar_path, "wb") as out_file:
            shutil.copyfileobj(resp, out_file)
    except Exception as e:
        sys.exit(f"Failed to download {url}: {e}")

    print("Extracting requested binaries...")
    exe_ext = ".exe" if sys.platform == "win32" else ""
    try:
        if filename.endswith(".tar.xz") or filename.endswith(".tar.gz"):
            mode = "r:xz" if filename.endswith(".tar.xz") else "r:gz"
            with tarfile.open(tar_path, mode) as tar:
                for member in tar.getmembers():
                    name = member.name
                    for tool in requested_tools:
                        target_name = f"{tool}{exe_ext}"
                        if name.endswith(f"/bin/{tool}") or name.endswith(f"/bin/{target_name}"):
                            dest = VENDOR_TOOLS / target_name
                            print(f"  ✓ Extracting {tool} -> {dest}")
                            f = tar.extractfile(member)
                            if f:
                                with open(dest, "wb") as out:
                                    out.write(f.read())
                                if sys.platform != "win32":
                                    os.chmod(dest, 0o755)
    finally:
        if tar_path.exists():
            tar_path.unlink()

    manifest_path = VENDOR_TOOLS / "manifest.json"
    manifest_data = {
        "note": "Populated by: python3 scripts/fetch_tools.py. Prefer system PATH tools.",
        "llvm_tag": tag,
        "tools": {t: {"version": tag} for t in requested_tools},
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest_data, f, indent=2)

    print("Done. vendor/tools/manifest.json updated.")


if __name__ == "__main__":
    main()
