# Tasks

Ongoing task list for the `tests/` stress-test effort (mc.toml-driven
project builds, exercised against real-world C codebases). Each item is
checked off and rewritten as a one-sentence, past-tense summary of what was
actually done; that same sentence is mirrored into `AGENTS.md`'s progress
log as one line. Don't rewrite the sentence again later — it's a record of
what happened, not a living description.

## Done

- [x] Ported custom multi-step T1 build recipes in test_legacy.py for tests 148-151 (linker symbols, copy relocations, linker boundaries, DSO symbols) and fixed tool PATH resolution in src/fmt/format.zig.
- [x] Added 2x weekly scheduled and force-dispatch release workflow on main targeting yyyy.mm.dd-mc-<hash> releases, and removed legacy edge pre-releases.
- [x] Adopted a PR-gated `main` workflow: added a no-bypass GitHub ruleset
      requiring Linux/macOS/Windows CI, moved `edge` publishing to `main`,
      removed `scripts/dev.py`, and deleted the retired `dev` branch.
- [x] Added URL-sourced C packages: package/application manifests, full Git URL
      dependencies, shared immutable checkout caching, committed `mc.lock`,
      `mc add`/`mc update`/`mc build --locked`, source/header graph integration,
      and local-Git end-to-end coverage.
- [x] Updated `mc init` to scaffold `src/main.c` (Hello World) and a clean `mc.toml`, changed default LSP `c_standard` to `c99`, and added end-to-end `mc init` test coverage in `test_toolchain.py`.
- [x] Verified `mc fmt`, `mc lint`, and `mc lsp` subcommands end-to-end in `tests/test_toolchain.py`: fixed a memory lifetime bug in `mc lsp` string array parsing, improved `mc lint` diagnostic line rendering and relative path formatting, and added comprehensive smoke tests covering style overrides, clang-tidy diagnostics, and JSON-RPC LSP compile database generation.
- [x] Enabled sound effects and music for `mc-mods/doomgeneric-sdl` with
      SDL2_mixer 2.8.1, added the `_WIN32` `<strings.h>` compatibility fix,
      updated the pinned stress fixture, and smoke-tested dummy video/audio.
- [x] Move test scripts into `tests/`: relocated `test_legacy.py`/
      `test_toolchain.py` from `scripts/` to `tests/`, updated `justfile`,
      `scripts/gate.py`, `scripts/dev.py`, and docs to match.
- [x] Project-mode `mc build`: `mc build` with no args now reads `mc.toml`
      (`[project]`/`[build]`: `sources`, `main`, `target`, `include_dirs`,
      `defines`), resolves sources (default `src/**/*.c`), and compiles to
      `target` (default `bin/<name>`); passthrough mode (`mc build <args>`)
      is unchanged.
- [x] Multi-`main()` guard: project-mode build hard-errors listing files
      when more than one resolved source defines a top-level `main()`,
      pointing at `build.sources`/`build.main` instead of surfacing tcc's
      raw linker error.
- [x] Cloned `mc-mods` (https://github.com/nightconcept/mc-mods.git,
      already existed empty) to `../mc-mods` and vendored sqlite-3.53.3
      (amalgamation + shell) with an mc.toml; needed one tcc-compat patch
      to `shell.c`'s Windows `fsdir` dirent shim (rewritten on plain
      Win32 `FindFirstFileW`/`FindNextFileW` since tcc's `msvcrt.def`
      doesn't export the CRT wide find-file symbols `<io.h>` expands to)
      plus `SQLITE_DISABLE_INTRINSIC` (tcc lacks MSVC's `__umulh`);
      verified `mc build` produces a working `sqlite3.exe` (create/
      insert/select smoke-tested). See `mc-mods/sqlite-3.53.3/PATCHES.md`.
- [x] Vendored Lua 5.4.8 in `mc-mods` as sibling `lua/`/`luac/` mc.toml
      projects sharing one `src/` (each listing the shared core+library
      sources explicitly, matching upstream `src/Makefile`'s
      `CORE_O`/`LIB_O`, plus their own main()-owning file) — a single
      mc.toml can't build both `lua.c` and `luac.c`'s binaries at once.
      No source patches needed; both set `LUA_USE_JUMPTABLE=0` via
      `build.defines` since tcc defines `__GNUC__` but not the GNU
      computed-goto extension lvm.c's default dispatch wants. Verified
      `mc build` for both and a `lua`/`luac` round-trip (`luac -o` then
      `lua` running the compiled chunk). See `mc-mods/lua-5.4.8/PATCHES.md`.
- [x] Pushed the `mc-mods` commits (sqlite-3.53.3, lua-5.4.8) to
      `nightconcept/mc-mods` `main`, with the user's explicit go-ahead.
- [x] `tests/stress/run_stress.py`: clones `mc-mods` pinned to commit
      `5156ca046bc47c8021b6b58bd3f49f7d8eee87f1` into the gitignored
      `tests/stress/.cache/`, runs `mc build` for sqlite3 and lua/luac,
      and smoke-tests each binary (sqlite create/insert/select; a
      luac-compiled chunk run by lua); wired as `just test-stress` and
      documented in `docs/testing.md`'s "Suites" section. Verified
      passing end-to-end from a clean cache.

## Next up

- [ ] tcc 3-stage bootstrap check (4th stress target): stage0 (current
      `scripts/build.py` output) compiles tcc's own sources → stage1;
      stage1 compiles them again → stage2; compare stage1/stage2 build
      output for a fixed test input as a determinism sanity check.
