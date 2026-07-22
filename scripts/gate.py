#!/usr/bin/env python3
"""Quality gate: fmt-check -> zig unit tests -> [build -> legacy -> toolchain]."""
import argparse
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = Path(__file__).parent

ZIG_SOURCES = [
    "packages/cli/mc.zig",
    "packages/fmt/format.zig",
    "packages/lint/lint.zig",
    "packages/lsp/lsp.zig",
    "build.zig",
]


def _run(cmd):
    result = subprocess.run(cmd, cwd=REPO_ROOT)
    if result.returncode != 0:
        sys.exit(result.returncode)


def _py(script, *args):
    _run([sys.executable, str(SCRIPTS / script), *args])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fast", action="store_true",
        help="Skip build and test suites (fmt check + zig unit tests only)",
    )
    args = parser.parse_args()

    # Filter to existing Zig sources
    existing = [s for s in ZIG_SOURCES if (REPO_ROOT / s).exists()]
    _run(["zig", "fmt", "--check", *existing])
    _run(["zig", "build", "check"])
    _py("test_toolchain.py", "--unit-only")

    if args.fast:
        return

    _py("build.py")
    _py("test_legacy.py")
    _py("test_toolchain.py")


if __name__ == "__main__":
    main()
