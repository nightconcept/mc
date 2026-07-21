#!/usr/bin/env python3
"""Unified build/test/package entrypoint for mc (ModC).

This drives the `mc` CLI (packages/cli/mc.zig) around a vendored copy of
the MIR project's C-to-MIR compiler (c2mir) at packages/compiler/ (see
packages/manifest.json for the pinned upstream commit, refreshed via
scripts/update-compiler.py). mc.zig embeds c2mir's driver (c2m_main,
renamed from main via -Dmain=c2m_main).

All build output (objects, libs, c2m, mc) lands in build/ via manual
zig cc / zig build-exe invocations -- MIR has its own GNUmakefile, but we
bypass it so the same zig toolchain drives every step. Packaged release
artifacts go in dist/ (also gitignored).
"""
import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
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

# MIR/c2mir need no libc replacement, just the platform threading lib.
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


# --------------------------------------------------------------------------
# build


def windows_system_include_dir():
    # c2mir.c only knows default system header search paths on
    # __APPLE__/__unix__ (see init_include_dirs in c2mir.c); on Windows it
    # has none, so C programs it compiles can't find stdio.h etc. Point it
    # at zig's bundled mingw-w64 headers via the ADDITIONAL_INCLUDE_PATH
    # hook that upstream already provides for exactly this case.
    out = subprocess.run([ZIG, "env"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    lib_dir = Path(re.search(r'\.lib_dir = "([^"]+)"', out).group(1))

    mingw_dir = lib_dir / "libc" / "include" / "any-windows-any"
    # mm_malloc.h isn't part of mingw's own headers -- it's a compiler-
    # intrinsics header the toolchain is expected to supply, which zig
    # ships separately from its libc headers. malloc.h pulls it in on
    # x86_64/i386, and ADDITIONAL_INCLUDE_PATH only takes one directory,
    # so drop it directly into zig's (ephemeral-on-CI) mingw dir rather
    # than staging a copy of the whole tree elsewhere.
    mm_malloc = mingw_dir / "mm_malloc.h"
    if not mm_malloc.exists():
        shutil.copy(lib_dir / "include" / "mm_malloc.h", mm_malloc)
    return mingw_dir


def build():
    if BUILD_DIR.exists():
        shutil.rmtree(BUILD_DIR)
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

    # Plain c2m: unmodified driver main(), used as the raw CLI and by the
    # legacy (vendored MIR c-tests) suite.
    driver_plain = BUILD_DIR / "c2mir" / f"c2mir-driver-plain{OBJ}"
    compile_obj(COMPILER_DIR / "c2mir" / "c2mir-driver.c", driver_plain)
    run([ZIG, "cc", str(driver_plain), str(libmir), "-o", str(BUILD_DIR / f"c2m{EXE}"), *MIR_LIBS])

    # Renamed driver (main -> c2m_main) linked into the mc.zig frontend.
    driver_renamed = BUILD_DIR / "c2mir" / f"c2mir-driver{OBJ}"
    run([
        ZIG, "cc", "-c", str(COMPILER_DIR / "c2mir" / "c2mir-driver.c"), "-o", str(driver_renamed),
        *include_flags, "-O2", "-Dmain=c2m_main",
    ])
    run([
        ZIG, "build-exe", "-O", "ReleaseSafe", f"-femit-bin=build/mc{EXE}",
        str(CLI_SRC), str(driver_renamed), str(libmir), *include_flags, "-lc", *MIR_LIBS,
    ])


def cmd_build(args):
    build()


# --------------------------------------------------------------------------
# test: legacy (vendored MIR c-tests suite, run against build/c2m)

# Pre-existing, architecture-specific test gaps in upstream MIR's own
# c-tests suite (not regressions from the mc/c2mir wiring here). Unlike
# its siblings reg.mir/reg2.mir, this test has no .mach guard excluding
# non-x86_64 hosts, but its comment is explicit that it exercises x86-64
# SysV va_list register-offset internals (gp_offset/fp_offset) that don't
# apply on aarch64.
KNOWN_NONPORTABLE_FAILURES = {
    "packages/compiler/c-tests/new/va-struct-args.c",
}

# Pre-existing Windows x86-64/ABI/JIT gaps in upstream MIR itself (not
# regressions from the mc/c2mir wiring here):
#   - mir-x86_64.c/mir-gen-x86_64.c explicitly refuse multiple return
#     values on the Windows ABI (issue279.mir)
#   - MIR's JIT symbol loader doesn't resolve __va_start on Windows, so
#     any varargs-via-va_start test aborts before running
#   - mingw's setjmp is an arch-specific macro c2mir's preprocessor
#     doesn't expand (setjmp2.c)
#   - mul-overflow.c assumes LP64 `long` (8 bytes); Windows is LLP64
#     (`long` is 4 bytes), so the overflow checks it exercises don't apply
#   - sub-overflow.c's abort() and issue202.c's empty-struct ABI hit
#     further Windows JIT/calling-convention gaps in the vendored MIR
# Separately (handled structurally below, not listed here) are two classes
# of pre-existing Windows-only gap that the c2mir header fix does NOT close:
#   - mingw-w64 headers c2mir still can't parse (e.g. math.h's GCC extended
#     inline-asm statements): the failure's diagnostics reference the mingw
#     header dir ("any-windows-any").
#   - programs that DO parse but then hit MIR's eager JIT symbol resolver on
#     Windows: mingw's static inline stdio helpers reference libmingwex-only
#     symbols (__local_stdio_printf_options), and c2mir lowers va_start to a
#     call to __va_start, neither of which MIR can resolve against the loaded
#     UCRT DLLs. Both surface as "can not load symbol ...".
# These are pre-existing upstream MIR limitations, not something this repo's
# build wiring can paper over.
KNOWN_WINDOWS_FAILURES = {
    "packages/compiler/c-tests/mir/issue279.mir",
    "packages/compiler/c-tests/new/va-ld-stack.c",
    "packages/compiler/c-tests/new/va-struct-args.c",
    "packages/compiler/c-tests/new/issue142.c",
    "packages/compiler/c-tests/new/issue441.c",
    "packages/compiler/c-tests/new/issue456.c",
    "packages/compiler/c-tests/lacc/vararg-complex-1.c",
    "packages/compiler/c-tests/lacc/long-double-function.c",
    "packages/compiler/c-tests/new/setjmp2.c",
    "packages/compiler/c-tests/new/mul-overflow.c",
    "packages/compiler/c-tests/new/sub-overflow.c",
    "packages/compiler/c-tests/new/issue202.c",
}


def cmd_test_legacy(args):
    c2m = BUILD_DIR / f"c2m{EXE}"
    # Passed to `sh`, whose glob patterns treat backslash as an escape
    # character -- Windows-style paths from Path.__str__ would garble the
    # `$ctest_dir/$dir/*.c` globs in runtests.sh, so force forward slashes.
    result = subprocess.run(
        [
            "sh",
            (COMPILER_DIR / "c-tests" / "runtests.sh").as_posix(),
            (COMPILER_DIR / "c-tests" / "use-c2m-gen").as_posix(),
            c2m.as_posix(),
        ],
        cwd=ROOT, capture_output=True, text=True,
    )
    print(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr)

    known = KNOWN_NONPORTABLE_FAILURES | (KNOWN_WINDOWS_FAILURES if IS_WINDOWS else set())
    # runtests.sh prints "$test_path:" without a trailing newline, then
    # appends FAIL/OK -- but a failing test's own diagnostic output lands
    # in between, pushing "FAIL" onto its own line disconnected from the
    # path. Track the most recently seen test path, and the diagnostic
    # lines since it started, across all lines so FAIL lines can still be
    # attributed and (on Windows) checked for a mingw-header parse gap.
    current_test = None
    diagnostics = []
    unexpected = []
    failed = 0
    for line in result.stdout.splitlines():
        match = re.search(r"([^\s:]+\.(?:c|mir)):", line)
        if match:
            current_test = match.group(1)
            diagnostics = []
        if "FAIL" in line:
            failed += 1
            listed = current_test and any(k in current_test for k in known)
            # A Windows failure is a known gap if it either couldn't parse a
            # mingw header, or parsed but hit MIR's eager JIT symbol resolver
            # on a mingw/varargs helper it can't provide (see comment above).
            mingw_header_gap = IS_WINDOWS and any("any-windows-any" in d for d in diagnostics)
            mingw_jit_gap = IS_WINDOWS and any(
                sym in d
                for d in diagnostics
                for sym in ("__local_stdio_printf_options", "__va_start")
            )
            if not listed and not mingw_header_gap and not mingw_jit_gap:
                unexpected.append(f"{current_test}: {line.strip()}")
        else:
            diagnostics.append(line)

    # Surface a clear pass/total so the CI log shows progress at a glance.
    # On Windows some failures are known-gap exemptions (see the comment on
    # KNOWN_WINDOWS_FAILURES and the structural checks above), so "passed"
    # counts every test file that isn't currently failing.
    m = re.search(r"Tests (\d+)", result.stdout)
    total = int(m.group(1)) if m else failed
    exempted = failed - len(unexpected)
    summary = f"legacy c-tests: {total - failed}/{total} test files passed"
    if failed:
        summary += f" ({exempted} known-gap exemption(s), {len(unexpected)} unexpected)"
    print(summary)

    if unexpected:
        sys.exit(f"legacy c-tests: {len(unexpected)} unexpected failure(s):\n" + "\n".join(unexpected))


# --------------------------------------------------------------------------
# test: toolchain (mc CLI behavior, not upstream compilation correctness)


def zig_unit_tests():
    run([ZIG, "test", str(CLI_SRC), "-lc"])


def smoke_test():
    mc_bin = BUILD_DIR / f"mc{EXE}"
    tmp = Path(tempfile.mkdtemp(prefix="mc-smoke-"))
    try:
        # On Windows, <stdio.h> pulls in mingw's static inline stdio helpers,
        # which reference libmingwex-only symbols MIR's JIT can't resolve; like
        # upstream's own sieve.c we hand-declare printf for the stdout-checking
        # cases. Real system-header support (which the c2mir header fix enables)
        # is exercised by real_header_c below and, extensively, by the legacy
        # c-tests.
        preamble = "void printf (const char *, ...);\n" if IS_WINDOWS else "#include <stdio.h>\n"

        hello_c = tmp / "hello.c"
        hello_c.write_text(f'{preamble}int main(void){{printf("Hello World\\n");return 0;}}\n')

        args_c = tmp / "args.c"
        args_c.write_text(
            f'{preamble}'
            'int main(int argc,char**argv){\n'
            '  for(int i=0;i<argc;i++) printf("arg %d: %s\\n", i, argv[i]);\n'
            '  return 0;\n'
            '}\n'
        )

        invalid_c = tmp / "invalid.c"
        invalid_c.write_text("int main(void) { return 0 }\n")  # missing semicolon: syntax error

        def mc(*a, **kw):
            kw.setdefault("cwd", tmp)
            return subprocess.run([str(mc_bin), *a], **kw)

        out = mc(str(hello_c), capture_output=True, text=True, check=True).stdout.strip()
        assert out == "Hello World", f"run failed: {out!r}"

        out = mc("run", str(args_c), "--", "one", "two", capture_output=True, text=True, check=True).stdout
        assert out.strip().splitlines()[-1] == "arg 2: two", "args test failed"

        # Real system-header compile+run. <string.h> is one of many headers the
        # c2mir header fix makes usable on Windows (unlike <stdio.h>, it drags
        # in no unresolved JIT helpers). Checked via exit code, so no stdout
        # wiring is needed and it runs identically on every platform.
        real_header_c = tmp / "real_header.c"
        real_header_c.write_text('#include <string.h>\nint main(void){ return (int) strlen("abcd"); }\n')
        rc = mc(str(real_header_c), capture_output=True, text=True).returncode
        assert rc == 4, f"real system-header compile/run failed: rc={rc}"

        hello_bin = tmp / f"hello{EXE}"
        mc("build", str(hello_c), "-c", "-o", str(hello_bin.with_suffix(".bmir")), check=True)

        mc("lint", str(hello_c), check=True)

        result = mc("lint", str(invalid_c), capture_output=True)
        if result.returncode == 0:
            sys.exit("mc lint accepted invalid C")

        mc("c2m", "-h", capture_output=True, check=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def cmd_test_toolchain(args):
    zig_unit_tests()
    smoke_test()


# --------------------------------------------------------------------------
# test: all (legacy gate first, then toolchain)


def cmd_test_all(args):
    cmd_test_legacy(args)
    cmd_test_toolchain(args)


# --------------------------------------------------------------------------
# package


def cmd_package(args):
    DIST_DIR.mkdir(exist_ok=True)
    shutil.copy(BUILD_DIR / f"mc{EXE}", DIST_DIR / artifact_name())


# --------------------------------------------------------------------------
# ci: full pipeline used by GitHub Actions


def cmd_ci(args):
    cmd_build(args)
    cmd_test_all(args)
    cmd_package(args)


# --------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("build", help="build mc (and c2m) into build/").set_defaults(func=cmd_build)

    p_test = sub.add_parser("test", help="run tests").add_subparsers(dest="test_target", required=True)
    p_test.add_parser("legacy", help="run the vendored MIR c-tests suite").set_defaults(func=cmd_test_legacy)
    p_test.add_parser("toolchain", help="run mc CLI/toolchain tests").set_defaults(func=cmd_test_toolchain)
    p_test.add_parser("all", help="legacy suite, then toolchain tests").set_defaults(func=cmd_test_all)

    sub.add_parser("package", help="copy the built binary into dist/").set_defaults(func=cmd_package)

    sub.add_parser("ci", help="build, test all, package").set_defaults(func=cmd_ci)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
