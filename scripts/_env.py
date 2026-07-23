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
    """Resolve a package directory from build.zig.zon hash in zig-pkg/."""
    zon = ROOT / "build.zig.zon"
    text = zon.read_text()
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if f".{dep_name}" in line:
            for j in range(i, len(lines)):
                if ".hash" in lines[j]:
                    hash_val = lines[j].split('"')[1]
                    pkg = ROOT / "zig-pkg" / hash_val
                    if pkg.exists():
                        return pkg
                    sys.exit(f"Package '{dep_name}' not found at: {pkg}")
    sys.exit(f"could not find hash for '{dep_name}' in build.zig.zon")


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
