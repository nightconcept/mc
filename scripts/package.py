#!/usr/bin/env python3
"""Copy build/mc into dist/ with a platform-stamped filename."""
import shutil
from _env import BUILD_DIR, DIST_DIR, EXE, artifact_name


def package():
    DIST_DIR.mkdir(exist_ok=True)
    shutil.copy(BUILD_DIR / f"mc{EXE}", DIST_DIR / artifact_name())


if __name__ == "__main__":
    package()
