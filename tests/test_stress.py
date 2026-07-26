#!/usr/bin/env python3
"""Stress-test harness: fetches the pinned mc-mods projects and builds/smoke-tests
each one with `mc build`, verifying the resulting binaries actually work."""
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from _env import ROOT, BUILD_DIR, EXE, IS_WINDOWS, run

MC_MODS_URL = "https://github.com/nightconcept/mc-mods.git"
MC_MODS_REF = "c89a388f413e499924bd14908b223289e32cdd74"
CACHE_DIR = ROOT / "tests" / ".cache" / "mc-mods"
MC = BUILD_DIR / f"mc{EXE}"

# Freedoom's freedoom1.wad (BSD-ish license, no id Software content) as the
# IWAD for the doomgeneric smoke test - avoids relying on id's shareware WAD.
FREEDOOM_URL = "https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip"
FREEDOOM_CACHE_DIR = ROOT / "tests" / ".cache" / "freedoom"
FREEDOOM_WAD = FREEDOOM_CACHE_DIR / "freedoom1.wad"

# Isolated from the user's real ~/.cache (or %LOCALAPPDATA%) mc runtime cache:
# fixed and known ahead of time so smoke_tcc_bootstrap can pass the same -B
# path to the tcc binaries it builds, without reimplementing mc.zig's
# cachePathFor platform logic in Python.
TCC_RUNTIME_CACHE = ROOT / "tests" / ".cache" / "mc-runtime"


def fetch_mc_mods():
    if not CACHE_DIR.exists():
        CACHE_DIR.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", MC_MODS_URL, str(CACHE_DIR)])
    run(["git", "fetch", "origin"], cwd=CACHE_DIR)
    run(["git", "checkout", MC_MODS_REF], cwd=CACHE_DIR)


def fetch_freedoom():
    if FREEDOOM_WAD.exists():
        return
    FREEDOOM_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    zip_path = FREEDOOM_CACHE_DIR / "freedoom.zip"
    urllib.request.urlretrieve(FREEDOOM_URL, zip_path)
    with zipfile.ZipFile(zip_path) as z:
        for name in z.namelist():
            if name.endswith("freedoom1.wad"):
                with z.open(name) as src, open(FREEDOOM_WAD, "wb") as dst:
                    dst.write(src.read())
                break
        else:
            sys.exit("freedoom1.wad not found in freedoom release zip")
    zip_path.unlink()


def mc_build(project_dir, env=None):
    subprocess.run([str(MC), "build"], cwd=project_dir, check=True, env=env)


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
    mc_build(project)
    lua_exe = project / "bin" / f"lua{EXE}"
    luac_exe = project / "bin" / f"luac{EXE}"

    script = project / "_smoke.lua"
    chunk = project / "_smoke.luac"
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


def smoke_tcc_bootstrap():
    """Three-stage self-hosting bootstrap: `mc build` (mc's embedded tcc)
    compiles tcc.c into tcc #1; tcc #1 then compiles the same tcc.c into
    tcc #2; tcc #2 compiles it again into tcc #3. tcc #2 and #3 should be
    byte-identical (upstream's classic self-hosting fixed point — tcc #1
    still carries mc's own toolchain's object-file quirks, but the loop
    converges after one self-compile)."""
    project = CACHE_DIR / "tinycc-aebb1436"
    env = os.environ.copy()
    env["MC_RUNTIME_CACHE_DIR"] = str(TCC_RUNTIME_CACHE)
    mc_build(project, env=env)
    tcc1 = project / "bin" / f"tcc{EXE}"

    def self_compile(compiler, out_name):
        out = project / "bin" / out_name
        subprocess.run(
            [str(compiler), "-B", str(TCC_RUNTIME_CACHE), "-I", "config", "-o", str(out), "src/tcc.c"],
            cwd=project,
            check=True,
        )
        return out

    tcc2 = self_compile(tcc1, f"tcc2{EXE}")
    tcc3 = self_compile(tcc2, f"tcc3{EXE}")

    for exe in (tcc1, tcc2, tcc3):
        subprocess.run([str(exe), "-v"], check=True)

    if tcc2.read_bytes() != tcc3.read_bytes():
        sys.exit("tcc bootstrap failed: tcc #2 and tcc #3 are not byte-identical")
    print("tcc bootstrap (mc -> tcc#1 -> tcc#2 -> tcc#3): OK")


def smoke_doomgeneric():
    """doomgeneric's SDL2 backend with SDL2_mixer sound. No -timedemo lump:
    freedoom ships no demo lumps, so this instead runs the normal title-screen
    loop for a few seconds under SDL's dummy video and audio drivers and checks
    it survives rather than crashing (e.g. the tcc compatibility bugs that the
    project's PATCHES.md documents). doomgeneric's stdio isn't reliably flushed
    when piped, so a live process at the deadline (TimeoutExpired) is the success
    signal, not captured stdout content."""
    if not IS_WINDOWS:
        print("doomgeneric: skipped (Windows-only vendored SDL2 for now)")
        return

    fetch_freedoom()
    project = CACHE_DIR / "doomgeneric-sdl"
    mc_build(project)

    bin_dir = project / "bin"
    exe = bin_dir / f"doomgeneric{EXE}"
    shutil.copy(project / "lib" / "SDL2.dll", bin_dir / "SDL2.dll")
    shutil.copy(project / "lib" / "SDL2_mixer.dll", bin_dir / "SDL2_mixer.dll")
    shutil.copy(FREEDOOM_WAD, bin_dir / "freedoom1.wad")

    env = os.environ.copy()
    env["SDL_VIDEODRIVER"] = "dummy"
    env["SDL_AUDIODRIVER"] = "dummy"
    try:
        result = subprocess.run(
            [str(exe), "-iwad", "freedoom1.wad"],
            cwd=bin_dir, env=env, capture_output=True, text=True, timeout=6,
        )
        sys.exit(f"doomgeneric exited early (rc={result.returncode}):\n{result.stdout}\n{result.stderr}")
    except subprocess.TimeoutExpired:
        pass
    print("doomgeneric (SDL2 + SDL2_mixer): OK")


def main():
    if not MC.exists():
        sys.exit(f"mc build not found at {MC}; run `just build` first")
    fetch_mc_mods()
    smoke_sqlite()
    smoke_lua()
    smoke_tcc_bootstrap()
    smoke_doomgeneric()
    print("stress tests passed")


if __name__ == "__main__":
    main()
