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


def ensure_zig_mingw_mm_malloc():
    # zig cc compiles tcc.c against its bundled mingw-w64 headers
    # (any-windows-any). malloc.h in that tree #includes <mm_malloc.h>, which the
    # any-windows-any set is missing, so drop zig's own shim copy into it (from
    # zig's generic include/ dir) before the driver compile below.
    out = subprocess.run([ZIG, "env"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    lib_dir = Path(re.search(r'\.lib_dir = "([^"]+)"', out).group(1))
    mingw_dir = lib_dir / "libc" / "include" / "any-windows-any"
    mm_malloc = mingw_dir / "mm_malloc.h"
    if not mm_malloc.exists():
        shutil.copy(lib_dir / "include" / "mm_malloc.h", mm_malloc)


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

    # tcc.c is compiled with zig cc (clang), so it must see a complete,
    # clang-compilable system header set. On Windows that means zig's bundled
    # mingw-w64 headers (any-windows-any) — NOT TinyCC's win32/include, which is
    # a stripped set that relies on tcc's own built-in type predefinitions
    # (intptr_t/uintptr_t) and fails to compile under clang. win32/include is
    # still shipped in mc-runtime for tcc's own use at runtime (see below).
    include_flags = ["-I", str(config_dir), "-I", str(compiler_dir)]

    def compile_obj(src, obj, extra_flags=()):
        run([ZIG, "cc", "-c", str(src), "-o", str(obj), *include_flags, "-O2", *extra_flags])

    # On multiarch Linux (Debian/Ubuntu) libc's headers and shared objects live
    # in per-triplet subdirs (/usr/include/<triplet>, /usr/lib/<triplet>) rather
    # than directly under /usr/include and /usr/lib. tcc only searches those
    # subdirs when CONFIG_TRIPLET is defined (see ALSO_TRIPLET in tcc.h); our
    # minimal config.h doesn't define it. Bake it in so both the standalone tcc
    # that self-compiles the runtime lib below AND the tcc linked into mc can
    # find <bits/libc-header-start.h> at compile time and libc at link time.
    # Not applicable to Windows (PE) or macOS (SDK-path based).
    driver_defines = []
    if os_name == "linux":
        triplet = {"x86_64": "x86_64-linux-gnu", "arm64": "aarch64-linux-gnu"}[arch]
        driver_defines = [f'-DCONFIG_TRIPLET="{triplet}"']

    # On Windows the runtime lib is self-compiled below by tcc, which (PE target)
    # only searches {B}/include (= compiler_dir/include, tcc's arch headers:
    # stdarg.h/stddef.h/...) for system headers and so can't find the CRT headers
    # (stdio.h etc). Feed it TinyCC's own win32/include set — NOT zig's mingw-w64
    # headers, whose vadefs.h #errors unless __GNUC__/_MSC_VER is defined (tcc
    # defines neither on _WIN32; see tccdefs.h). win32/include ships a
    # tcc-compatible vadefs.h and is the same header set shipped in mc-runtime
    # for tcc's own use at runtime (see header_dir below), so the runtime lib is
    # built against exactly the headers it will later be linked against.
    # <windows.h> lives in the winapi/ subdir, so both dirs are needed.
    runtime_sysinclude = []
    if IS_WINDOWS:
        ensure_zig_mingw_mm_malloc()
        win32_include = compiler_dir / "win32" / "include"
        runtime_sysinclude = [win32_include.as_posix(), (win32_include / "winapi").as_posix()]

    # Plain tcc driver. tcc.c is itself a unity ("ONE_SOURCE") build that
    # #includes libtcc.c (which in turn pulls in tccpp.c/tccgen.c/tccdbg.c/
    # tccasm.c/tccelf.c/tccrun.c and the arch backend) — analogous to MIR's
    # mir.c/mir-gen.c/c2mir.c triple, but as a single translation unit. Built
    # first so it can self-host the runtime-library compile below.
    driver_plain = BUILD_DIR / f"tcc-driver-plain{OBJ}"
    compile_obj(compiler_dir / "tcc.c", driver_plain, driver_defines)
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
            *[arg for path in runtime_sysinclude for arg in ("-I", path)],
        ])
        return obj

    archive_objs = [self_compile(name) for name in archive_srcs]
    libtcc1 = runtime_stage / "libtcc1.a"
    run([str(tcc_exe), "-ar", "rcs", str(libtcc1), *[str(o) for o in archive_objs]])

    loose_objs = [self_compile(name) for name in loose_srcs]

    # Stage the embedded runtime archive: headers + libtcc1.a + loose
    # objects, extracted by mc.zig at first run via `-B<cache>`.
    #
    # On non-Windows the shipped headers are just tcc's own arch/predef set
    # (include/*.h: tccdefs.h, stdarg.h, stddef.h, ...); system CRT headers come
    # from the host (/usr/include, macOS SDK). On Windows there is no host libc
    # to lean on, so tcc ships the whole CRT header set (win32/include, including
    # its winapi/, sys/, sec_api/ subdirs) AND the arch/predef headers merged in
    # on top — matching upstream's Windows install (Makefile install-win / win32
    # build-tcc.bat). tccdefs.h in particular must be present: our minimal
    # config.h doesn't compile the predefs in, so tcc reads {B}/include/tccdefs.h
    # at runtime.
    runtime_root = BUILD_DIR / "mc-runtime"
    include_dst = runtime_root / "include"
    include_dst.mkdir(parents=True)
    if IS_WINDOWS:
        shutil.copytree(compiler_dir / "win32" / "include", include_dst, dirs_exist_ok=True)
    for header in (compiler_dir / "include").glob("*.h"):
        shutil.copy(header, include_dst / header.name)
    shutil.copy(compiler_dir / "tcclib.h", include_dst / "tcclib.h")
    # libtcc1.a and the loose support objects (runmain/bt-*/bcheck) are found
    # via tcc's library search path at runtime. On ELF/Mach-O targets that path
    # is {B} itself, but on PE it is {B}/lib (CONFIG_TCC_LIBPATHS in tcc.h), so
    # nest them under lib/ on Windows. tcc also requests the support objects by
    # their .o name (tcc_add_support "runmain.o", "bt-exe.o", ...), so rename the
    # Windows .obj outputs to .o.
    lib_dst = runtime_root / "lib" if IS_WINDOWS else runtime_root
    lib_dst.mkdir(exist_ok=True)
    shutil.copy(libtcc1, lib_dst / "libtcc1.a")
    for obj in loose_objs:
        shutil.copy(obj, lib_dst / (obj.stem + ".o" if IS_WINDOWS else obj.name))

    # On Windows the C math functions live in msvcrt (auto-linked by tcc's PE
    # backend), so there is no separate libm — but portable code still links
    # -lm. Ship an empty libm.a stub so -lm resolves, exactly as mingw-w64 does;
    # the math symbols themselves come from msvcrt. (On ELF/Mach-O the host libc
    # provides a real libm, so this is Windows-only.)
    if IS_WINDOWS:
        run([str(tcc_exe), "-ar", "rcs", str(lib_dst / "libm.a")])

    runtime_tar = BUILD_DIR / "mc-runtime.tar"
    with tarfile.open(runtime_tar, "w") as tar:
        for item in sorted(runtime_root.iterdir()):
            tar.add(item, arcname=item.name)

    # Renamed driver (main -> tcc_main) linked into the mc.zig frontend
    driver_renamed = BUILD_DIR / f"tcc-driver{OBJ}"
    compile_obj(compiler_dir / "tcc.c", driver_renamed, [*driver_defines, "-Dmain=tcc_main"])

    # Build mc frontend linking Zig packages
    toml_pkg = package_dir("toml") / "src" / "root.zig"
    run([
        ZIG, "build-exe", "-O", "ReleaseSafe", f"-femit-bin=build/mc{EXE}",
        "--dep", "fmt", "--dep", "lint", "--dep", "lsp", "--dep", "runtime", "--dep", "toml", "--dep", "packages",
        f"-Mroot={CLI_SRC}",
        "--dep", "toml", f"-Mfmt={ROOT / 'src' / 'fmt' / 'format.zig'}",
        "--dep", "toml", "--dep", "fmt", f"-Mlint={ROOT / 'src' / 'lint' / 'lint.zig'}",
        "--dep", "toml", "--dep", "fmt", "--dep", "packages", f"-Mlsp={ROOT / 'src' / 'lsp' / 'lsp.zig'}",
        "--dep", "toml=toml_ext", f"-Mtoml={ROOT / 'src' / 'toml' / 'toml.zig'}",
        f"-Mtoml_ext={toml_pkg}",
        "--dep", "toml", f"-Mpackages={ROOT / 'src' / 'packages' / 'packages.zig'}",
        f"-Mruntime={BUILD_DIR / 'runtime_embed.zig'}",
        str(driver_renamed), *include_flags, "-lc", *TCC_LIBS,
    ])


if __name__ == "__main__":
    build()
