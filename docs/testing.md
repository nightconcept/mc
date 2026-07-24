# Testing

## Suites

- **Zig unit tests** — run as part of `scripts/test_toolchain.py` (and by
  `just gate-fast`). Wires each `src/<name>/` package together via
  `--dep`/`-M` flags; see `zig_unit_tests()` in
  `scripts/test_toolchain.py` for the exact module graph.
- **Legacy (`just test-legacy`)** — `scripts/test_legacy.py` runs TinyCC's
  vendored `tests/tests2/*.c` + `*.expect` suite against `build/tcc`.
  Each `NN_name.c` is compared byte-for-byte against `NN_name.expect`,
  usually via `tcc -run`. A handful of upstream tests use a custom
  multi-file/`T1` Makefile recipe we haven't ported and are skipped
  (see `SKIP_CUSTOM_RECIPE` in that script).
- **Toolchain (`just test-toolchain`)** — `scripts/test_toolchain.py` runs
  Zig unit tests plus `mc` CLI smoke tests (not TinyCC compilation
  correctness).
- **Both (`just test`)** — legacy first, then toolchain. Order matters:
  a broken compiler should fail before CLI-level tests run.

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
