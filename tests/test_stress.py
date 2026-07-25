#!/usr/bin/env python3
"""Stress-test harness: fetches the pinned mc-mods projects and builds/smoke-tests
each one with `mc build`, verifying the resulting binaries actually work."""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "scripts"))
from _env import ROOT, BUILD_DIR, EXE, run

MC_MODS_URL = "https://github.com/nightconcept/mc-mods.git"
MC_MODS_REF = "5156ca046bc47c8021b6b58bd3f49f7d8eee87f1"
CACHE_DIR = ROOT / "tests" / "stress" / ".cache" / "mc-mods"
MC = BUILD_DIR / f"mc{EXE}"


def fetch_mc_mods():
    if not CACHE_DIR.exists():
        CACHE_DIR.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", MC_MODS_URL, str(CACHE_DIR)])
    run(["git", "fetch", "origin"], cwd=CACHE_DIR)
    run(["git", "checkout", MC_MODS_REF], cwd=CACHE_DIR)


def mc_build(project_dir):
    subprocess.run([str(MC), "build"], cwd=project_dir, check=True)


def smoke_sqlite():
    project = CACHE_DIR / "sqlite-3.53.3"
    mc_build(project)
    exe = project / "bin" / f"sqlite3{EXE}"
    script = (
        "CREATE TABLE t(a,b);\n"
        "INSERT INTO t VALUES(1,'hello'),(2,'world');\n"
        "SELECT * FROM t;\n"
        ".quit\n"
    )
    result = subprocess.run(
        [str(exe)], input=script, cwd=project, capture_output=True, text=True, check=True
    )
    expected = "1|hello\n2|world\n"
    if result.stdout != expected:
        sys.exit(f"sqlite smoke test failed:\nexpected: {expected!r}\ngot: {result.stdout!r}")
    print("sqlite3: OK")


def smoke_lua():
    project = CACHE_DIR / "lua-5.4.8"
    lua_dir = project / "lua"
    luac_dir = project / "luac"
    mc_build(lua_dir)
    mc_build(luac_dir)
    lua_exe = lua_dir / "bin" / f"lua{EXE}"
    luac_exe = luac_dir / "bin" / f"luac{EXE}"

    script = luac_dir / "_smoke.lua"
    chunk = luac_dir / "_smoke.luac"
    script.write_text(
        'print("compiled by luac")\n'
        "local t = {1,2,3}\n"
        "local sum = 0\n"
        "for _, v in ipairs(t) do sum = sum + v end\n"
        'print("sum:", sum)\n'
    )
    try:
        subprocess.run([str(luac_exe), "-o", str(chunk), str(script)], check=True)
        result = subprocess.run(
            [str(lua_exe), str(chunk)], capture_output=True, text=True, check=True
        )
    finally:
        script.unlink(missing_ok=True)
        chunk.unlink(missing_ok=True)
    expected = "compiled by luac\nsum:\t6\n"
    if result.stdout != expected:
        sys.exit(f"lua smoke test failed:\nexpected: {expected!r}\ngot: {result.stdout!r}")
    print("lua/luac: OK")


def main():
    if not MC.exists():
        sys.exit(f"mc build not found at {MC}; run `just build` first")
    fetch_mc_mods()
    smoke_sqlite()
    smoke_lua()
    print("stress tests passed")


if __name__ == "__main__":
    main()
