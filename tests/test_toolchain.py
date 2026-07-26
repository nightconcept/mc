#!/usr/bin/env python3
"""Run zig unit tests and mc CLI smoke tests."""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from _env import BUILD_DIR, CLI_SRC, EXE, IS_WINDOWS, ROOT, ZIG, package_dir, run


def zig_unit_tests():
    toml_pkg = package_dir("toml") / "src" / "root.zig"
    run([
        ZIG, "test",
        "--dep", "fmt", "--dep", "lint", "--dep", "lsp", "--dep", "runtime", "--dep", "toml",
        f"-Mroot={CLI_SRC}",
        "--dep", "toml", f"-Mfmt={ROOT / 'src' / 'fmt' / 'format.zig'}",
        "--dep", "toml", "--dep", "fmt", f"-Mlint={ROOT / 'src' / 'lint' / 'lint.zig'}",
        "--dep", "toml", "--dep", "fmt", f"-Mlsp={ROOT / 'src' / 'lsp' / 'lsp.zig'}",
        "--dep", "toml=toml_ext", f"-Mtoml={ROOT / 'src' / 'toml' / 'toml.zig'}",
        f"-Mtoml_ext={toml_pkg}",
        f"-Mruntime={BUILD_DIR / 'runtime_embed.zig'}",
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

        hello_obj = tmp / ("hello.obj" if IS_WINDOWS else "hello.o")
        mc("build", str(hello_c), "-c", "-o", str(hello_obj), check=True)

        # Test mc fmt and mc fmt --check
        mc("fmt", str(hello_c), check=True)
        result = mc("fmt", "--check", str(hello_c), capture_output=True)
        assert result.returncode == 0, f"mc fmt --check failed: {result.stderr.decode('utf-8') if isinstance(result.stderr, bytes) else result.stderr}"

        # Test mc lint --syntax-only
        mc("lint", "--syntax-only", str(hello_c), check=True)

        result = mc("lint", "--syntax-only", str(invalid_c), capture_output=True)
        if result.returncode == 0:
            sys.exit("mc lint accepted invalid C")

        mc("tcc", "-h", capture_output=True, check=True)

        fmt_test(tmp)
        lint_test(tmp)
        lsp_test(tmp)
        project_mode_lib_test(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def fmt_test(tmp):
    """Test `mc fmt` formatting and `mc.toml` [fmt] configuration."""
    mc_bin = BUILD_DIR / f"mc{EXE}"
    fmt_dir = tmp / "fmt_test"
    fmt_dir.mkdir(parents=True, exist_ok=True)

    unformatted_c = fmt_dir / "unformatted.c"
    unformatted_c.write_text("int main(void){int x=1;return x;}\n")

    # Format in-place
    subprocess.run([str(mc_bin), "fmt", str(unformatted_c)], cwd=fmt_dir, check=True)
    assert "int x = 1;" in unformatted_c.read_text(), "mc fmt failed to format file"

    # --check on formatted file should succeed
    res = subprocess.run([str(mc_bin), "fmt", "--check", str(unformatted_c)], cwd=fmt_dir, capture_output=True)
    assert res.returncode == 0, f"mc fmt --check failed on formatted file: {res.stderr.decode('utf-8', errors='replace')}"

    # Test mc.toml [fmt] section style overrides
    (fmt_dir / "mc.toml").write_text('[project]\nname = "fmt_test"\n\n[fmt]\nIndentWidth = 2\n')
    unformatted_c.write_text("int main(void) {\nint x = 1;\nreturn x;\n}\n")
    subprocess.run([str(mc_bin), "fmt", str(unformatted_c)], cwd=fmt_dir, check=True)
    assert "  int x = 1;" in unformatted_c.read_text(), "mc fmt with mc.toml [fmt] IndentWidth=2 failed"


def lint_test(tmp):
    """Test `mc lint` syntax gate, full clang-tidy pass, diagnostic formatting, and `mc.toml` [lint]."""
    mc_bin = BUILD_DIR / f"mc{EXE}"
    lint_dir = tmp / "lint_test"
    lint_dir.mkdir(parents=True, exist_ok=True)

    clean_c = lint_dir / "clean.c"
    clean_c.write_text("int main(void) { return 0; }\n")

    invalid_c = lint_dir / "invalid.c"
    invalid_c.write_text("int main(void) { return 0 }\n")

    bad_lint_c = lint_dir / "bad_lint.c"
    bad_lint_c.write_text("int main(void) { char a[5]; a[10] = 0; return 0; }\n")

    # --syntax-only checks
    subprocess.run([str(mc_bin), "lint", "--syntax-only", str(clean_c)], cwd=lint_dir, check=True)
    res = subprocess.run([str(mc_bin), "lint", "--syntax-only", str(invalid_c)], cwd=lint_dir, capture_output=True)
    assert res.returncode != 0, "mc lint --syntax-only accepted invalid C syntax"

    # Full clang-tidy pass on clean file
    subprocess.run([str(mc_bin), "lint", str(clean_c)], cwd=lint_dir, check=True)

    # Full clang-tidy pass on file with lint issues & verify diagnostic formatting
    res = subprocess.run([str(mc_bin), "lint", str(bad_lint_c)], cwd=lint_dir, capture_output=True, text=True)
    stderr = res.stderr
    assert "warning[readability-magic-numbers]" in stderr or "warning[clang-analyzer-security.ArrayBound]" in stderr, (
        f"mc lint output missing expected clang-tidy warnings: {stderr!r}"
    )
    assert "-->" in stderr, f"mc lint output missing diagnostic line pointer: {stderr!r}"
    assert "|" in stderr, f"mc lint output missing snippet line formatting: {stderr!r}"

    # Test mc.toml [lint] configuration
    (lint_dir / "mc.toml").write_text('[project]\nname = "lint_test"\n\n[lint]\nchecks = "readability-magic-numbers"\n')
    res = subprocess.run([str(mc_bin), "lint", str(bad_lint_c)], cwd=lint_dir, capture_output=True, text=True)
    assert "readability-magic-numbers" in res.stderr, f"mc lint with mc.toml [lint] checks failed: {res.stderr!r}"


def lsp_test(tmp):
    """Test `mc lsp` compile_commands.json generation and clangd bridge startup."""
    import json
    import time

    mc_bin = BUILD_DIR / f"mc{EXE}"
    lsp_dir = tmp / "lsp_test"
    lsp_dir.mkdir(parents=True, exist_ok=True)

    (lsp_dir / "include").mkdir()
    (lsp_dir / "include" / "hdr.h").write_text("#define VAL 42\n")
    (lsp_dir / "src").mkdir()
    (lsp_dir / "src" / "main.c").write_text('#include "hdr.h"\nint main(void) { return VAL; }\n')

    (lsp_dir / "mc.toml").write_text(
        '[project]\nname = "lsptest"\n\n[build]\nc_standard = "c11"\ninclude_dirs = ["include"]\ndefines = ["APP_VER=1"]\n'
    )

    proc = subprocess.Popen(
        [str(mc_bin), "lsp"],
        cwd=lsp_dir,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        cc_json = lsp_dir / ".mccache" / "compile_commands.json"
        for _ in range(20):
            if cc_json.exists():
                break
            time.sleep(0.1)

        assert cc_json.exists(), "mc lsp failed to generate .mccache/compile_commands.json"
        data = json.loads(cc_json.read_text())
        assert len(data) > 0, "compile_commands.json is empty"
        cmd = data[0].get("command", "")
        assert "-std=c11" in cmd, f"-std=c11 missing in compile_commands.json: {cmd!r}"
        assert "-Iinclude" in cmd, f"-Iinclude missing in compile_commands.json: {cmd!r}"
        assert "-DAPP_VER=1" in cmd, f"-DAPP_VER=1 missing in compile_commands.json: {cmd!r}"
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()


def project_mode_lib_test(tmp):
    """`mc build` (project mode) linking a vendored shared library via
    build.lib_dirs/build.libs: build a tiny DLL/.so with passthrough mode
    (-shared -rdynamic), then a project-mode consumer that links it two
    ways - explicit lib_dirs, and the implicit default `lib/` directory."""
    mc_bin = BUILD_DIR / f"mc{EXE}"
    if IS_WINDOWS:
        dll_suffix = ".dll"
    elif sys.platform == "darwin":
        dll_suffix = ".dylib"
    else:
        dll_suffix = ".so"
    dll_name = f"{'' if IS_WINDOWS else 'lib'}addlib{dll_suffix}"

    libproj = tmp / "libproj"
    (libproj / "lib").mkdir(parents=True)
    addlib_c = libproj / "addlib.c"
    addlib_c.write_text("int add(int a, int b) { return a + b; }\n")
    dll_path = libproj / "lib" / dll_name
    subprocess.run(
        [str(mc_bin), "build", "-shared", "-rdynamic", str(addlib_c), "-o", str(dll_path)],
        check=True,
    )

    preamble = "void printf (const char *, ...);\n" if IS_WINDOWS else "#include <stdio.h>\n"
    main_c_src = f'{preamble}int add(int a, int b);\nint main(void){{printf("result: %d\\n", add(2, 3));return 0;}}\n'

    def build_and_run(project_dir, mc_toml_build_section):
        project_dir.mkdir(parents=True, exist_ok=True)
        (project_dir / "src").mkdir()
        (project_dir / "src" / "main.c").write_text(main_c_src)
        (project_dir / "mc.toml").write_text(
            f'[project]\nname = "{project_dir.name}"\n\n[build]\n{mc_toml_build_section}\n'
        )
        subprocess.run([str(mc_bin), "build"], cwd=project_dir, check=True)
        bin_dir = project_dir / "bin"
        shutil.copy(dll_path, bin_dir / dll_name)
        exe = bin_dir / f"{project_dir.name}{EXE}"
        out = subprocess.run([str(exe)], cwd=bin_dir, capture_output=True, text=True, check=True).stdout
        assert out.strip() == "result: 5", f"lib link test failed: {out!r}"

    build_and_run(tmp / "consumer_explicit", 'lib_dirs = ["../libproj/lib"]\nlibs = ["addlib"]')

    # implicit default: no lib_dirs set, but ./lib exists under the project.
    consumer_default = tmp / "consumer_default"
    (consumer_default / "lib").mkdir(parents=True)
    shutil.copy(dll_path, consumer_default / "lib" / dll_name)
    build_and_run(consumer_default, 'libs = ["addlib"]')


def test_toolchain(unit_only=False):
    zig_unit_tests()
    if not unit_only:
        smoke_test()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unit-only", action="store_true", help="Run Zig unit tests only")
    args = parser.parse_args()
    test_toolchain(unit_only=args.unit_only)

