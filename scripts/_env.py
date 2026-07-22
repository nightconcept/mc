#!/usr/bin/env python3
"""Shared constants and helpers for mc build scripts."""
import os
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI_SRC = ROOT / "src" / "cli" / "mc.zig"
BUILD_DIR = ROOT / "build"
DIST_DIR = ROOT / "dist"
ZIG = os.environ.get("ZIG", "zig")
IS_WINDOWS = sys.platform == "win32"
EXE = ".exe" if IS_WINDOWS else ""
OBJ = ".obj" if IS_WINDOWS else ".o"
MIR_LIBS = [] if IS_WINDOWS else ["-lpthread"]


def _zig_global_cache() -> Path:
    """Return the Zig global cache directory."""
    result = subprocess.run(
        [ZIG, "env"], cwd=ROOT, capture_output=True, text=True, check=True
    )
    for line in result.stdout.splitlines():
        if line.strip().startswith(".global_cache_dir"):
            return Path(line.split('"')[1])
    sys.exit("could not determine zig global cache dir")


def mir_dir() -> Path:
    """Resolve the MIR source directory from the local zig-pkg/ extraction."""
    zon = ROOT / "build.zig.zon"
    text = zon.read_text()
    # Extract the hash value from the .zon file
    for line in text.splitlines():
        if ".hash" in line:
            hash_val = line.split('"')[1]
            break
    else:
        sys.exit("could not find mir hash in build.zig.zon")
    pkg = ROOT / "zig-pkg" / hash_val
    if not pkg.exists():
        sys.exit(
            f"MIR package not found at: {pkg}\n"
            "Run: mise exec -- zig fetch --save=mir <url>  or  just update-mir <sha>"
        )
    return pkg


# Resolved lazily — call mir_dir() in scripts that need C sources.
# Kept as a module-level alias so existing callers work unchanged.
COMPILER_DIR = None  # use mir_dir() instead


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
