#!/usr/bin/env python3
"""Compile TinyCC (C) and the mc Zig frontend into build/."""
import platform
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path
from _env import (
    BUILD_DIR, CLI_SRC, EXE, IS_WINDOWS, TCC_LIBS, OBJ, ROOT, ZIG, package_dir, run, tinycc_dir,
)

# Runtime-support object sources, mirrored from upstream TinyCC's
# src/lib/Makefile OBJ-<target> lists. Split into:
#  - archive: objects packed into libtcc1.a (embedded in mc, extracted via -B)
#  - loose: objects shipped unarchived alongside libtcc1.a (used by tcc at
#    runtime for -run's main-wrapper, backtraces, and bounds checking)
COMMON_ARCHIVE = ["stdatomic.c", "atomic.S", "builtin.c", "alloca.S", "alloca-bt.S", "tcov.c"]
COMMON_LOOSE = ["runmain.c", "bt-exe.c", "bt-log.c", "bcheck.c"]


def host_arch():
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        return "x86_64"
    if machine in ("arm64", "aarch64"):
        return "arm64"
    sys.exit(f"unsupported host arch for tinycc runtime: {machine}")


def runtime_sources(os_name, arch):
    archive = list(COMMON_ARCHIVE)
    loose = list(COMMON_LOOSE)
    if os_name == "windows":
        archive += [
            "libtcc1.c", "chkstk.S",
            "crt1.c", "crt1w.c", "wincrt1.c", "wincrt1w.c", "dllcrt1.c", "dllmain.c", "winex.c",
        ]
        loose += ["bt-dll.c"]
    elif arch == "x86_64":
        archive += ["libtcc1.c", "va_list.c"]
        if os_name == "linux":
            archive += ["dsohandle.c"]
    elif arch == "arm64":
        archive += ["lib-arm64.c"]
        if os_name == "linux":
            archive += ["armflush.c", "dsohandle.c"]
    else:
        sys.exit(f"unsupported arch for tinycc runtime: {arch}")
    return archive, loose


def find_source(compiler_dir, name):
    for candidate in (compiler_dir / "lib" / name, compiler_dir / "win32" / "lib" / name):
        if candidate.exists():
            return candidate
    sys.exit(f"tinycc runtime source not found: {name}")


def windows_system_include_dir():
    # TinyCC's own win32/include headers are self-contained (no MinGW/system
    # headers needed), but zig cc still needs its bundled mm_malloc.h shim
    # the same way c2mir's Windows build did — see git history for the MIR
    # equivalent of this helper.
    out = subprocess.run([ZIG, "env"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    lib_dir = Path(re.search(r'\.lib_dir = "([^"]+)"', out).group(1))
    mingw_dir = lib_dir / "libc" / "include" / "any-windows-any"
    mm_malloc = mingw_dir / "mm_malloc.h"
    if not mm_malloc.exists():
        shutil.copy(lib_dir / "include" / "mm_malloc.h", mm_malloc)
    return mingw_dir


def build():
    if BUILD_DIR.exists():
        shutil.rmtree(BUILD_DIR)
    BUILD_DIR.mkdir(parents=True)

    compiler_dir = tinycc_dir()
    os_name = "windows" if IS_WINDOWS else platform.system().lower()
    arch = host_arch()

    # Minimal config.h: tcc.h #include "config.h" unconditionally, but every
    # macro it defines has an #ifndef-guarded fallback except TCC_VERSION.
    # TCC_TARGET_*/TCC_TARGET_PE/TCC_TARGET_MACHO are auto-detected from host
    # compiler builtins (__x86_64__/__aarch64__/_WIN32/__APPLE__) when unset.
    config_dir = BUILD_DIR / "tcc-config"
    config_dir.mkdir(parents=True)
    version = (compiler_dir / "VERSION").read_text().strip()
    (config_dir / "config.h").write_text(f'#define TCC_VERSION "{version}"\n')
    (BUILD_DIR / "tcc-version.txt").write_text(version)

    # @embedFile can't escape its module's root directory, so the runtime
    # archive is exposed through a tiny module rooted in build/ itself
    # (see the "runtime" --dep wired into the build-exe/zig-test commands
    # below) rather than embedded directly from src/cli/mc.zig.
    (BUILD_DIR / "runtime_embed.zig").write_text(
        'pub const archive = @embedFile("mc-runtime.tar");\n'
        'pub const version = @embedFile("tcc-version.txt");\n'
    )

    include_flags = ["-I", str(config_dir), "-I", str(compiler_dir)]
    if IS_WINDOWS:
        include_flags += ["-I", str(compiler_dir / "win32" / "include")]

    def compile_obj(src, obj, extra_flags=()):
        run([ZIG, "cc", "-c", str(src), "-o", str(obj), *include_flags, "-O2", *extra_flags])

    tcc_flags = []
    if IS_WINDOWS:
        tcc_flags = [f'-DADDITIONAL_INCLUDE_PATH="{windows_system_include_dir().as_posix()}"']

    # Plain tcc driver. tcc.c is itself a unity ("ONE_SOURCE") build that
    # #includes libtcc.c (which in turn pulls in tccpp.c/tccgen.c/tccdbg.c/
    # tccasm.c/tccelf.c/tccrun.c and the arch backend) — analogous to MIR's
    # mir.c/mir-gen.c/c2mir.c triple, but as a single translation unit. Built
    # first so it can self-host the runtime-library compile below.
    driver_plain = BUILD_DIR / f"tcc-driver-plain{OBJ}"
    compile_obj(compiler_dir / "tcc.c", driver_plain, tcc_flags)
    tcc_exe = BUILD_DIR / f"tcc{EXE}"
    run([ZIG, "cc", str(driver_plain), "-o", str(tcc_exe), *TCC_LIBS])

    # Runtime-support library (libtcc1.a): TinyCC's lib/*.c and *.S sources
    # are dual-mode (`#ifdef __TINYC__` vs. a real-compiler branch) and,
    # crucially, tcc's own object loader (tcc_object_type in tccelf.c) only
    # recognizes ELF/AR magic for externally-supplied .o files — it can't
    # load a foreign Mach-O (or likely COFF) object at all. So the runtime
    # must be self-hosted with the freshly-built tcc above (upstream's
    # default, non-"usegcc" path), not compiled with zig cc directly.
    archive_srcs, loose_srcs = runtime_sources(os_name, arch)
    runtime_stage = BUILD_DIR / "runtime"
    runtime_stage.mkdir(parents=True)

    def self_compile(name):
        src = find_source(compiler_dir, name)
        obj = runtime_stage / (Path(name).stem + OBJ)
        run([
            str(tcc_exe), "-c", str(src), "-o", str(obj),
            "-B", str(compiler_dir), "-I", str(compiler_dir), "-I", str(config_dir),
        ])
        return obj

    archive_objs = [self_compile(name) for name in archive_srcs]
    libtcc1 = runtime_stage / "libtcc1.a"
    run([str(tcc_exe), "-ar", "rcs", str(libtcc1), *[str(o) for o in archive_objs]])

    loose_objs = [self_compile(name) for name in loose_srcs]

    # Stage the embedded runtime archive: headers + libtcc1.a + loose
    # objects, extracted by mc.zig at first run via `-B<cache>`.
    runtime_root = BUILD_DIR / "mc-runtime"
    (runtime_root / "include").mkdir(parents=True)
    header_dir = compiler_dir / "win32" / "include" if IS_WINDOWS else compiler_dir / "include"
    for header in header_dir.glob("*.h"):
        shutil.copy(header, runtime_root / "include" / header.name)
    shutil.copy(compiler_dir / "tcclib.h", runtime_root / "include" / "tcclib.h")
    shutil.copy(libtcc1, runtime_root / "libtcc1.a")
    for obj in loose_objs:
        shutil.copy(obj, runtime_root / obj.name)

    runtime_tar = BUILD_DIR / "mc-runtime.tar"
    with tarfile.open(runtime_tar, "w") as tar:
        for item in sorted(runtime_root.iterdir()):
            tar.add(item, arcname=item.name)

    # Renamed driver (main -> tcc_main) linked into the mc.zig frontend
    driver_renamed = BUILD_DIR / f"tcc-driver{OBJ}"
    compile_obj(compiler_dir / "tcc.c", driver_renamed, [*tcc_flags, "-Dmain=tcc_main"])

    # Build mc frontend linking Zig packages
    toml_pkg = package_dir("toml") / "src" / "root.zig"
    run([
        ZIG, "build-exe", "-O", "ReleaseSafe", f"-femit-bin=build/mc{EXE}",
        "--dep", "fmt", "--dep", "lint", "--dep", "lsp", "--dep", "runtime",
        f"-Mroot={CLI_SRC}",
        "--dep", "toml", f"-Mfmt={ROOT / 'src' / 'fmt' / 'format.zig'}",
        "--dep", "toml", "--dep", "fmt", f"-Mlint={ROOT / 'src' / 'lint' / 'lint.zig'}",
        "--dep", "toml", "--dep", "fmt", f"-Mlsp={ROOT / 'src' / 'lsp' / 'lsp.zig'}",
        "--dep", "toml=toml_ext", f"-Mtoml={ROOT / 'src' / 'toml' / 'toml.zig'}",
        f"-Mtoml_ext={toml_pkg}",
        f"-Mruntime={BUILD_DIR / 'runtime_embed.zig'}",
        str(driver_renamed), *include_flags, "-lc", *TCC_LIBS,
    ])


if __name__ == "__main__":
    build()
