#!/usr/bin/env python3
"""Copy build/mc into dist/ with a platform-stamped filename."""
import os
import shutil
import sys
from _env import BUILD_DIR, DIST_DIR, EXE, artifact_name

# build.py stamps the -mcpu it used. A native-CPU binary is only valid on the
# machine that built it (a release built on an AVX-512 runner SIGILLs on every
# older CPU), so refuse to stage one as a distributable artifact unless the
# caller says it is deliberate.
CPU_STAMP = BUILD_DIR / "cpu.txt"
ALLOW_NATIVE_ENV = "MC_PACKAGE_ALLOW_NATIVE"


def check_portable():
    if os.environ.get(ALLOW_NATIVE_ENV):
        return
    cpu = CPU_STAMP.read_text().strip() if CPU_STAMP.exists() else "native"
    if cpu == "native":
        sys.exit(
            f"refusing to package a '-mcpu={cpu}' build: it bakes in this machine's "
            "CPU extensions and will crash with SIGILL elsewhere.\n"
            "Run 'just build-portable' (or 'just ci') first, or set "
            f"{ALLOW_NATIVE_ENV}=1 to package a host-only binary anyway."
        )


def package():
    check_portable()
    DIST_DIR.mkdir(exist_ok=True)
    shutil.copy(BUILD_DIR / f"mc{EXE}", DIST_DIR / artifact_name())


if __name__ == "__main__":
    package()
