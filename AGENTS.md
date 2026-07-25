# ⚠ This file is hard-limited to ≤100 lines. Update spokes, not the hub.

# ModC (mc) Agent Guide

## Intent

Maintain the ModC compiler toolchain with small, reviewable changes. The
compiler is a thin `mc` frontend (Zig) around TinyCC; first-party packages
(cli, fmt, lint, lsp, toml) live under `src/`.

## Stack

- Monorepo: `src/<name>/` holds each first-party package; root is workspace
  tooling only (`justfile`, `mise.toml`, `scripts/`)
- `src/cli/mc.zig` — the `mc` CLI frontend
- `build.zig.zon` — declares the TinyCC dep (nightconcept/tinycc `mtc`
  branch, pinned to a commit/ref; update with `just update-tinycc`)
- TinyCC sources live in the Zig global package cache (not in the repo);
  its runtime library (`libtcc1.a` + headers) is self-hosted-compiled and
  embedded into `mc` — see `scripts/build.py`
- `scripts/` — build/test/package CLI, driven via `just` (tools pinned in `mise.toml`)

## Documentation Hub (Spokes)

- [Architecture](docs/architecture.md) — layout, TinyCC dependency, runtime
  embedding, package boundaries
- [Development Build](docs/development.md) — `just build`/`clean`/`package`/
  `ci`, building the `mc` tool itself
- [Build command](docs/build.md) — the `mc build` CLI subcommand (compile a
  user's C file to an artifact)
- [Run command](docs/run.md) — the `mc run` CLI subcommand and bare
  `mc file.c` shorthand (JIT compile + execute)
- [Format](docs/fmt.md) — `mc fmt` style resolution and `just fmt` (Zig
  sources)
- [Lint](docs/lint.md) — `mc lint` checks and usage
- [Testing](docs/testing.md) — legacy/toolchain suites, quality gates
- [Conventions](docs/conventions.md) — commit style, code style, tool pins
- [Tasks](docs/TASKS.md) — ongoing task tracker; check items off and log a
  one-line summary here when done (see below)

## Essential Commands

- **Tools**: `mise install` (zig, python, just, lefthook), then `just hooks-install`
- **Gate**: `just gate-fast` (fmt + zig unit tests, runs pre-commit — needs one
  prior `just build` since `mc.zig` embeds the compiled tcc runtime archive)
  or `just gate` (adds build + legacy + toolchain tests, runs pre-push)
- **Build the tool**: `just build` — out-of-tree build into `build/`
  (objects, libs, `tcc`, `mc`); repo root and `src/` stay clean. Not to be
  confused with the `mc build` CLI subcommand (see `docs/build.md`).
- **Test legacy (vendored upstream TinyCC tests2 suite)**: `just test-legacy`
- **Test toolchain (mc CLI, not compilation)**: `just test-toolchain`
- **Test both, legacy first**: `just test`
- **Stress test project-mode `mc build`**: `just test-stress` (clones
  nightconcept/mc-mods, needs network; see `docs/testing.md`)
- **Package**: `just package` — copies `build/mc` into `dist/`
- **Format Zig**: `just fmt`
- **Lint C**: `./build/mc lint <file.c>` after `just build`
- **Update TinyCC**: push to nightconcept/tinycc `mtc` branch, then
  `just update-tinycc`

## Progress Log

One line per completed `docs/TASKS.md` item, most recent first. Prune old
entries to keep this file ≤100 lines; the detailed record lives in
`docs/TASKS.md`.

- Added `build.lib_dirs`/`build.libs` to project-mode `mc build` (`-L`/`-l`,
  `lib_dirs` defaulting to `lib/` if present); vendored `mc-mods/doomgeneric-sdl`
  (doomgeneric's SDL2 backend, sound dropped) as the first consumer and a
  new `test_stress.py` smoke test. Found and fixed a real tcc-compat bug
  along the way: doomgeneric's `doomtype.h` redefined `strncasecmp`/
  `strcasecmp` as macros, which rewrote tcc's own win32 header's inline
  definitions of those names into infinite self-recursion (stack overflow
  on first call).
- Added `tests/stress/run_stress.py` (`just test-stress`): builds/smoke-tests
  `mc-mods`' sqlite3 and lua/luac projects via project-mode `mc build`.
- Pushed `mc-mods` (sqlite-3.53.3, lua-5.4.8) to `nightconcept/mc-mods`.
- Vendored Lua 5.4.8 in `mc-mods` as sibling `lua/`/`luac/` mc.toml
  projects; verified `mc build` + a `luac`/`lua` round-trip.
- Vendored sqlite-3.53.3 in `mc-mods` with a tcc-compat `shell.c` patch;
  verified `mc build` produces a working `sqlite3.exe`.
- Added a multi-`main()` guard to project-mode `mc build`.
- Implemented project-mode `mc build` (`mc.toml` [build] -> tcc).

## Engineering Standards

- Convention over configuration: `mc.toml` sections should have sensible
  defaults that need zero config for the common case; add keys for
  overriding the exception, not the rule.
- Match surrounding code and avoid unrelated formatting changes.
- Keep TinyCC updates (via `just update-tinycc`) as their own commit,
  separate from `mc`-side changes.
- Commits **must** follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
- Run the smallest relevant test before committing; use `just test-legacy` for
  compiler changes and `just test-toolchain` for `mc` CLI changes. Legacy
  tests always gate before toolchain tests — `just test` enforces that order.

See `docs/conventions.md` and `docs/testing.md` for detail.
