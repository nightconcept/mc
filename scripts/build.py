#!/usr/bin/env python3
"""Compile MIR/c2mir (C) and the mc Zig frontend into build/."""
import re
import shutil
import subprocess
import sys
from pathlib import Path
from _env import (
    BUILD_DIR, CLI_SRC, COMPILER_DIR, EXE, IS_WINDOWS, MIR_LIBS, OBJ, ROOT, ZIG, run,
)


def windows_system_include_dir():
    # c2mir.c only knows default system header search paths on
    # __APPLE__/__unix__ (see init_include_dirs in c2mir.c); on Windows it
    # has none, so C programs it compiles can't find stdio.h etc. Point it
    # at zig's bundled mingw-w64 headers via the ADDITIONAL_INCLUDE_PATH
    # hook that upstream already provides for exactly this case.
    import shutil as _shutil
    out = subprocess.run([ZIG, "env"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    lib_dir = Path(re.search(r'\.lib_dir = "([^"]+)"', out).group(1))

    mingw_dir = lib_dir / "libc" / "include" / "any-windows-any"
    mm_malloc = mingw_dir / "mm_malloc.h"
    if not mm_malloc.exists():
        _shutil.copy(lib_dir / "include" / "mm_malloc.h", mm_malloc)
    return mingw_dir


def build():
    import shutil as _shutil
    if BUILD_DIR.exists():
        _shutil.rmtree(BUILD_DIR)
    (BUILD_DIR / "c2mir").mkdir(parents=True)

    include_flags = ["-I", str(COMPILER_DIR), "-I", str(COMPILER_DIR / "c2mir")]

    def compile_obj(src, obj, extra_flags=()):
        run([ZIG, "cc", "-c", str(src), "-o", str(obj), *include_flags, "-O2", *extra_flags])

    c2mir_flags = []
    if IS_WINDOWS:
        c2mir_flags = [f'-DADDITIONAL_INCLUDE_PATH="{windows_system_include_dir().as_posix()}"']

    compile_obj(COMPILER_DIR / "mir.c", BUILD_DIR / f"mir{OBJ}")
    compile_obj(COMPILER_DIR / "mir-gen.c", BUILD_DIR / f"mir-gen{OBJ}")
    compile_obj(COMPILER_DIR / "c2mir" / "c2mir.c", BUILD_DIR / "c2mir" / f"c2mir{OBJ}", c2mir_flags)

    libmir = BUILD_DIR / "libmir.a"
    run([
        ZIG, "ar", "rcs", str(libmir),
        str(BUILD_DIR / f"mir{OBJ}"),
        str(BUILD_DIR / f"mir-gen{OBJ}"),
        str(BUILD_DIR / "c2mir" / f"c2mir{OBJ}"),
    ])

    # Plain c2m driver
    driver_plain = BUILD_DIR / "c2mir" / f"c2mir-driver-plain{OBJ}"
    compile_obj(COMPILER_DIR / "c2mir" / "c2mir-driver.c", driver_plain)
    run([ZIG, "cc", str(driver_plain), str(libmir), "-o", str(BUILD_DIR / f"c2m{EXE}"), *MIR_LIBS])

    # Renamed driver (main -> c2m_main) linked into the mc.zig frontend
    driver_renamed = BUILD_DIR / "c2mir" / f"c2mir-driver{OBJ}"
    run([
        ZIG, "cc", "-c", str(COMPILER_DIR / "c2mir" / "c2mir-driver.c"), "-o", str(driver_renamed),
        *include_flags, "-O2", "-Dmain=c2m_main",
    ])

    # Build mc frontend linking Zig packages
    run([
        ZIG, "build-exe", "-O", "ReleaseSafe", f"-femit-bin=build/mc{EXE}",
        "--dep", "fmt", "--dep", "lint", "--dep", "lsp",
        f"-Mroot={CLI_SRC}",
        "--dep", "toml", f"-Mfmt={ROOT / 'packages' / 'fmt' / 'format.zig'}",
        "--dep", "toml", "--dep", "fmt", f"-Mlint={ROOT / 'packages' / 'lint' / 'lint.zig'}",
        "--dep", "toml", "--dep", "fmt", f"-Mlsp={ROOT / 'packages' / 'lsp' / 'lsp.zig'}",
        f"-Mtoml={ROOT / 'vendor' / 'toml' / 'toml.zig'}",
        str(driver_renamed), str(libmir), *include_flags, "-lc", *MIR_LIBS,
    ])


if __name__ == "__main__":
    build()
