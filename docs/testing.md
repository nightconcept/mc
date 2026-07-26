# Testing

## Suites

- **Zig unit tests** — run as part of `tests/test_toolchain.py` (and by
  `just gate-fast`). Wires each `src/<name>/` package together via
  `--dep`/`-M` flags; see `zig_unit_tests()` in
  `tests/test_toolchain.py` for the exact module graph.
- **Legacy (`just test-legacy`)** — `tests/test_legacy.py` runs TinyCC's
  vendored `tests/tests2/*.c` + `*.expect` suite (upstream's own tests/
  dir, inside the fetched tinycc source, not this repo's `tests/`) against
  `build/tcc`. Each `NN_name.c` is compared byte-for-byte against
  `NN_name.expect`, usually via `tcc -run`. A handful of upstream tests use
  a custom multi-file/`T1` Makefile recipe we haven't ported and are
  skipped (see `SKIP_CUSTOM_RECIPE` in that script).
- **Toolchain (`just test-toolchain`)** — `tests/test_toolchain.py` runs
  Zig unit tests plus `mc` CLI smoke tests (not TinyCC compilation
  correctness).
- **Both (`just test`)** — legacy first, then toolchain. Order matters:
  a broken compiler should fail before CLI-level tests run.
- **Stress (`just test-stress`)** — `tests/test_stress.py` clones
  [nightconcept/mc-mods](https://github.com/nightconcept/mc-mods) (vendored,
  mc-friendly copies of real-world C projects) at a pinned commit into the
  gitignored `tests/.cache/`, runs `mc build` (project-mode) in each
  project, and smoke-tests the resulting binary. Covers the two real-world
  problems project-mode `mc build` needs to handle: the "multiple `main()`"
  problem (sqlite3's amalgamation + shell) and multi-binary source sharing
  (Lua's `lua`/`luac`, via `build.outputs` in `lua-5.4.8/mc.toml`). Also
  runs a three-stage self-hosting bootstrap on a vendored TinyCC checkout
  (`tinycc-<commit>/`): `mc build` (mc's embedded tcc) produces tcc #1,
  tcc #1 compiles the same `tcc.c` into tcc #2, tcc #2 compiles it again
  into tcc #3 — tcc #2 and #3 must come out byte-identical. Also builds
  `doomgeneric-sdl/` (doomgeneric's SDL2 backend with SDL2_mixer sound) via
  `build.lib_dirs`/`build.libs`, and runs it headlessly with SDL's dummy
  video and audio drivers plus a fetched `freedoom1.wad` for a few seconds
  to check it doesn't crash — Windows-only for now. Needs a prior `just
  build` and network access; not part of `just test`/`gate` — run it
  explicitly when touching project-mode `mc build`.

## Quality gates

- `just gate-fast` — `zig fmt --check` + `zig build check` + Zig unit
  tests. Needs one prior `just build` (see `docs/development.md`). Runs as
  the `pre-commit` lefthook.
- `just gate` — `gate-fast` plus a full build + `just test`. Runs as the
  `pre-push` lefthook.

## Picking a test before committing

Run the smallest relevant suite: `just test-legacy` for compiler/TinyCC
changes, `just test-toolchain` for `mc` CLI changes. Don't rely on
`gate-fast` alone for compiler changes — it doesn't run the legacy suite.
