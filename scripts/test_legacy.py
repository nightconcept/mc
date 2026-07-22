#!/usr/bin/env python3
"""Run the vendored MIR c-tests suite against build/c2m."""
import re
import subprocess
import sys
from _env import BUILD_DIR, EXE, IS_WINDOWS, ROOT, mir_dir

# Pre-existing, architecture-specific test gaps in upstream MIR's own
# c-tests suite (not regressions from the mc/c2mir wiring here). Unlike
# its siblings reg.mir/reg2.mir, this test has no .mach guard excluding
# non-x86_64 hosts, but its comment is explicit that it exercises x86-64
# SysV va_list register-offset internals (gp_offset/fp_offset) that don't
# apply on aarch64.
KNOWN_NONPORTABLE_FAILURES = {
    "va-struct-args.c",
}

# Pre-existing Windows x86-64/ABI/JIT gaps in upstream MIR itself (not
# regressions from the mc/c2mir wiring here):
KNOWN_WINDOWS_FAILURES = {
    "issue279.mir",
    "va-ld-stack.c",
    "va-struct-args.c",
    "issue142.c",
    "issue441.c",
    "issue456.c",
    "vararg-complex-1.c",
    "long-double-function.c",
    "setjmp2.c",
    "mul-overflow.c",
    "sub-overflow.c",
    "issue202.c",
}


def test_legacy():
    c2m = BUILD_DIR / f"c2m{EXE}"
    compiler_dir = mir_dir()
    result = subprocess.run(
        [
            "sh",
            (compiler_dir / "c-tests" / "runtests.sh").as_posix(),
            (compiler_dir / "c-tests" / "use-c2m-gen").as_posix(),
            c2m.as_posix(),
        ],
        cwd=ROOT, capture_output=True, text=True,
    )
    print(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr)

    known = KNOWN_NONPORTABLE_FAILURES | (KNOWN_WINDOWS_FAILURES if IS_WINDOWS else set())
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

    m = re.search(r"Tests (\d+)", result.stdout)
    total = int(m.group(1)) if m else failed
    exempted = failed - len(unexpected)
    summary = f"legacy c-tests: {total - failed}/{total} test files passed"
    if failed:
        summary += f" ({exempted} known-gap exemption(s), {len(unexpected)} unexpected)"
    print(summary)

    if unexpected:
        sys.exit(f"legacy c-tests: {len(unexpected)} unexpected failure(s):\n" + "\n".join(unexpected))


if __name__ == "__main__":
    test_legacy()
