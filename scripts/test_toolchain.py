#!/usr/bin/env python3
"""Run zig unit tests and mc CLI smoke tests."""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from _env import BUILD_DIR, CLI_SRC, EXE, IS_WINDOWS, ROOT, ZIG, run


def zig_unit_tests():
    run([
        ZIG, "test",
        "--dep", "fmt", "--dep", "lint", "--dep", "lsp",
        f"-Mroot={CLI_SRC}",
        "--dep", "toml", f"-Mfmt={ROOT / 'src' / 'fmt' / 'format.zig'}",
        "--dep", "toml", "--dep", "fmt", f"-Mlint={ROOT / 'src' / 'lint' / 'lint.zig'}",
        "--dep", "toml", "--dep", "fmt", f"-Mlsp={ROOT / 'src' / 'lsp' / 'lsp.zig'}",
        f"-Mtoml={ROOT / 'src' / 'toml' / 'toml.zig'}",
        "-lc",
    ])


def ensure_tools_available():
    if shutil.which("clang-format"):
        return
    # Check .tools/ populated by fetch_tools.py (CI cache or local fetch)
    exe_ext = ".exe" if IS_WINDOWS else ""
    local_tools = ROOT / ".tools"
    clang_format = local_tools / f"clang-format{exe_ext}"
    if clang_format.exists():
        # Prepend .tools/ to PATH so mc subprocess finds the tools
        os.environ["PATH"] = str(local_tools) + os.pathsep + os.environ.get("PATH", "")
        return
    print("clang-format not found on PATH or .tools/. Fetching LLVM tools...")
    run([sys.executable, str(ROOT / "scripts" / "fetch_tools.py")])


def smoke_test():
    ensure_tools_available()
    mc_bin = BUILD_DIR / f"mc{EXE}"
    tmp = Path(tempfile.mkdtemp(prefix="mc-smoke-"))
    try:
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
        invalid_c.write_text("int main(void) { return 0 }\n")

        def mc(*a, **kw):
            kw.setdefault("cwd", tmp)
            return subprocess.run([str(mc_bin), *a], **kw)

        out = mc(str(hello_c), capture_output=True, text=True, check=True).stdout.strip()
        assert out == "Hello World", f"run failed: {out!r}"

        out = mc("run", str(args_c), "--", "one", "two", capture_output=True, text=True, check=True).stdout
        assert out.strip().splitlines()[-1] == "arg 2: two", "args test failed"

        real_header_c = tmp / "real_header.c"
        real_header_c.write_text('#include <string.h>\nint main(void){ return (int) strlen("abcd"); }\n')
        rc = mc(str(real_header_c), capture_output=True, text=True).returncode
        assert rc == 4, f"real system-header compile/run failed: rc={rc}"

        hello_bin = tmp / f"hello{EXE}"
        mc("build", str(hello_c), "-c", "-o", str(hello_bin.with_suffix(".bmir")), check=True)

        # Test mc fmt and mc fmt --check
        mc("fmt", str(hello_c), check=True)
        result = mc("fmt", "--check", str(hello_c), capture_output=True)
        assert result.returncode == 0, f"mc fmt --check failed: {result.stderr.decode('utf-8') if isinstance(result.stderr, bytes) else result.stderr}"

        # Test mc lint --syntax-only
        mc("lint", "--syntax-only", str(hello_c), check=True)

        result = mc("lint", "--syntax-only", str(invalid_c), capture_output=True)
        if result.returncode == 0:
            sys.exit("mc lint accepted invalid C")

        mc("c2m", "-h", capture_output=True, check=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_toolchain(unit_only=False):
    zig_unit_tests()
    if not unit_only:
        smoke_test()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unit-only", action="store_true", help="Run Zig unit tests only")
    args = parser.parse_args()
    test_toolchain(unit_only=args.unit_only)
