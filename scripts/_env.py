#!/usr/bin/env python3
"""Shared constants and helpers for mc build scripts."""
import os
import platform
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI_SRC = ROOT / "src" / "cli" / "mc.zig"
BUILD_DIR = ROOT / "build"
DIST_DIR = ROOT / "dist"
ZIG = os.environ.get("ZIG", "zig")
IS_WINDOWS = sys.platform == "win32"
IS_LINUX = sys.platform.startswith("linux")
EXE = ".exe" if IS_WINDOWS else ""
OBJ = ".obj" if IS_WINDOWS else ".o"
TCC_LIBS = [] if IS_WINDOWS else ["-lpthread"] + (["-ldl"] if IS_LINUX else [])


def _zig_global_cache() -> Path:
    """Return the Zig global cache directory."""
    result = subprocess.run(
        [ZIG, "env"], cwd=ROOT, capture_output=True, text=True, check=True
    )
    for line in result.stdout.splitlines():
        if line.strip().startswith(".global_cache_dir"):
            return Path(line.split('"')[1])
    sys.exit("could not determine zig global cache dir")


def package_dir(dep_name: str) -> Path:
    """Resolve a package directory from build.zig.zon hash in zig-pkg/, fetching and
    extracting it on demand if it isn't there yet (e.g. on a fresh checkout or CI
    cache miss)."""
    zon = ROOT / "build.zig.zon"
    text = zon.read_text()
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if f".{dep_name}" in line:
            url = None
            hash_val = None
            for j in range(i, len(lines)):
                if ".url" in lines[j] and url is None:
                    url = lines[j].split('"')[1]
                if ".hash" in lines[j]:
                    hash_val = lines[j].split('"')[1]
                    break
            if hash_val is None:
                sys.exit(f"could not find hash for '{dep_name}' in build.zig.zon")
            pkg = ROOT / "zig-pkg" / hash_val
            if pkg.exists():
                return pkg
            if url is None:
                sys.exit(f"could not find url for '{dep_name}' in build.zig.zon")
            return _fetch_package(dep_name, url, hash_val)
    sys.exit(f"could not find hash for '{dep_name}' in build.zig.zon")


def _fetch_package(dep_name: str, url: str, hash_val: str) -> Path:
    """Fetch a build.zig.zon dependency into the Zig global cache, then extract the
    cached tarball into zig-pkg/<hash>/ so scripts can read its sources directly."""
    pkg = ROOT / "zig-pkg" / hash_val
    print(f"+ fetching {dep_name} ({url})", flush=True)
    run([ZIG, "fetch", url])
    tarball = _zig_global_cache() / "p" / f"{hash_val}.tar.gz"
    if not tarball.exists():
        sys.exit(
            f"'zig fetch' did not produce the expected tarball for '{dep_name}': {tarball}\n"
            f"(build.zig.zon hash may be stale for {url})"
        )
    pkg.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(tarball, "r:gz") as tar:
        tar.extractall(pkg.parent)
    if not pkg.exists():
        sys.exit(f"extraction of '{dep_name}' did not produce expected dir: {pkg}")
    return pkg


def tinycc_dir() -> Path:
    """Resolve the TinyCC source directory from the local zig-pkg/ extraction."""
    return package_dir("tinycc") / "src"


def run(cmd, **kw):
    kw.setdefault("cwd", ROOT)
    print("+", " ".join(str(c) for c in cmd), flush=True)
    subprocess.run(cmd, check=True, **kw)


def artifact_name():
    if IS_WINDOWS:
        return "mc-windows-x64.exe"
    system = platform.system()
    if system == "Darwin":
        return "mc-macos-arm64"
    if system == "Linux":
        return "mc-linux-x64"
    sys.exit(f"unsupported build host: {system}")
