#!/usr/bin/env python3
"""Shared constants and helpers for mc build scripts."""
import os
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMPILER_DIR = ROOT / "packages" / "compiler"
CLI_SRC = ROOT / "packages" / "cli" / "mc.zig"
BUILD_DIR = ROOT / "build"
DIST_DIR = ROOT / "dist"
ZIG = os.environ.get("ZIG", "zig")
IS_WINDOWS = sys.platform == "win32"
EXE = ".exe" if IS_WINDOWS else ""
OBJ = ".obj" if IS_WINDOWS else ".o"
MIR_LIBS = [] if IS_WINDOWS else ["-lpthread"]


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
