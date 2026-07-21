#!/usr/bin/env python3
"""Quality gate: fmt -> unit -> build -> legacy -> toolchain."""

import argparse
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent


def _run(cmd):
    result = subprocess.run(cmd, cwd=REPO_ROOT)
    if result.returncode != 0:
        sys.exit(result.returncode)


def main():
    parser = argparse.ArgumentParser(description="Quality gate: fmt -> unit -> build -> test")
    parser.add_argument(
        "--fast", action="store_true",
        help="Skip build and test suites (fmt check + zig unit tests only)",
    )
    args = parser.parse_args()

    cli_src = REPO_ROOT / "packages" / "cli" / "mc.zig"
    _run(["zig", "fmt", "--check", str(cli_src)])
    _run(["zig", "test", str(cli_src), "-lc"])

    if args.fast:
        return

    _run(["python3", str(REPO_ROOT / "scripts" / "dev.py"), "build"])
    _run(["python3", str(REPO_ROOT / "scripts" / "dev.py"), "test", "legacy"])
    _run(["python3", str(REPO_ROOT / "scripts" / "dev.py"), "test", "toolchain"])


if __name__ == "__main__":
    main()
