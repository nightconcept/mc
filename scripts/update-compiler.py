#!/usr/bin/env python3
"""Re-vendor packages/compiler/ from https://github.com/vnmakarov/mir.

Resolves --ref (default: master) to a commit sha via `git ls-remote`,
downloads that commit's tarball from GitHub codeload, and mirrors it into
packages/compiler/ (no .git left behind). Updates the "compiler" entry in
packages/manifest.json with the new commit, ref, and vendor date.
"""
import argparse
import datetime
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMPILER_DIR = ROOT / "packages" / "compiler"
MANIFEST_PATH = ROOT / "packages" / "manifest.json"
REPO_URL = "https://github.com/vnmakarov/mir"


def resolve_commit(ref):
    out = subprocess.run(
        ["git", "ls-remote", REPO_URL, ref],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    if not out:
        sys.exit(f"could not resolve ref {ref!r} against {REPO_URL}")
    return out.splitlines()[0].split()[0]


def fetch_tree(commit, dest):
    tarball_url = f"{REPO_URL}/archive/{commit}.tar.gz"
    with tempfile.NamedTemporaryFile(suffix=".tar.gz") as tmp:
        print(f"+ downloading {tarball_url}", flush=True)
        urllib.request.urlretrieve(tarball_url, tmp.name)
        with tarfile.open(tmp.name) as tar:
            names = tar.getnames()
            root_dir = names[0].split("/")[0]
            tar.extractall(dest, filter="data")
    return dest / root_dir


def sync_tree(src, dest):
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest)


def load_manifest():
    if MANIFEST_PATH.exists():
        return json.loads(MANIFEST_PATH.read_text())
    return {"packages": {}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="master", help="branch/tag to resolve (default: master)")
    parser.add_argument("--dry-run", action="store_true", help="resolve the commit but don't fetch/write anything")
    args = parser.parse_args()

    commit = resolve_commit(args.ref)
    print(f"resolved {args.ref} -> {commit}")
    if args.dry_run:
        return

    with tempfile.TemporaryDirectory() as tmp:
        extracted = fetch_tree(commit, Path(tmp))
        sync_tree(extracted, COMPILER_DIR)

    manifest = load_manifest()
    manifest.setdefault("packages", {})["compiler"] = {
        "source": REPO_URL,
        "ref": args.ref,
        "commit": commit,
        "vendored_at": datetime.date.today().isoformat(),
        "path": "packages/compiler",
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"vendored packages/compiler/ at {commit}, manifest updated")


if __name__ == "__main__":
    main()
