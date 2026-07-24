#!/usr/bin/env python3
"""Backwards-compat shim — delegates to focused scripts in scripts/ and tests/.

Prefer calling the individual scripts directly:
  python3 scripts/build.py
  python3 tests/test_legacy.py
  python3 tests/test_toolchain.py
  python3 scripts/package.py
"""
import argparse
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).parent
TESTS = SCRIPTS.parent / "tests"


def _run(script, *extra):
    subprocess.run([sys.executable, str(SCRIPTS / script), *extra], check=True)


def _run_test(script, *extra):
    subprocess.run([sys.executable, str(TESTS / script), *extra], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("build")
    p = sub.add_parser("test")
    p.add_argument("target", choices=["legacy", "toolchain", "all"])
    sub.add_parser("package")
    sub.add_parser("ci")
    args = parser.parse_args()

    if args.cmd == "build":
        _run("build.py")
    elif args.cmd == "test":
        if args.target in ("legacy", "all"):
            _run_test("test_legacy.py")
        if args.target in ("toolchain", "all"):
            _run_test("test_toolchain.py")
    elif args.cmd == "package":
        _run("package.py")
    elif args.cmd == "ci":
        _run("build.py")
        _run_test("test_legacy.py")
        _run_test("test_toolchain.py")
        _run("package.py")


if __name__ == "__main__":
    main()
