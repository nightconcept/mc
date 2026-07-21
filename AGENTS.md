# ⚠ This file is hard-limited to ≤100 lines. Update spokes, not the hub.

# ModC (mc) Agent Guide

## Intent

Maintain the ModC compiler toolchain with small, reviewable changes. The
compiler is a thin `mc` frontend (Zig) around a vendored copy of MIR/c2mir;
future packages (linter, formatter) will join it under `packages/`.

## Stack

- Monorepo: `packages/<name>/` holds each buildable component; root is
  workspace tooling only (`justfile`, `mise.toml`, `scripts/`)
- `packages/cli/mc.zig` — the `mc` CLI frontend
- `packages/compiler/` — vendored copy of https://github.com/vnmakarov/mir
  (C-to-MIR compiler, c2mir); pinned commit tracked in `packages/manifest.json`
- `scripts/update-compiler.py` — re-vendors `packages/compiler/` from
  upstream MIR and refreshes the manifest
- `scripts/dev.py` build/test/package CLI, driven via `just` (tools pinned in `mise.toml`)

## Essential Commands

- **Tools**: `mise install` (zig, python, just, lefthook), then `just hooks-install`
- **Gate**: `just gate-fast` (fmt + zig unit tests, runs pre-commit) or
  `just gate` (adds build + legacy + toolchain tests, runs pre-push)
- **Build**: `just build` — out-of-tree build into `build/` (objects, libs,
  `c2m`, `mc`); repo root and `packages/` stay clean
- **Test legacy (vendored upstream MIR c-tests suite)**: `just test-legacy`
- **Test toolchain (mc CLI, not compilation)**: `just test-toolchain`
- **Test both, legacy first**: `just test`
- **Package**: `just package` — copies `build/mc` into `dist/`
- **Format Zig**: `zig fmt packages/cli/mc.zig`
- **Lint C**: `./build/mc lint <file.c>` after `just build`
- **Update vendored compiler**: `python3 scripts/update-compiler.py` (add
  `--ref <branch>` to pin something other than `master`, `--dry-run` to
  just resolve the commit)

## Engineering Standards

- Match surrounding code and avoid unrelated formatting changes.
- Keep `packages/compiler` re-vendors as their own commit (via
  `scripts/update-compiler.py`), separate from `mc`-side changes.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for commits,
  such as `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, and `chore:`.
- Run the smallest relevant test before committing; use `just test-legacy` for
  compiler changes and `just test-toolchain` for `mc` CLI changes. Legacy
  tests always gate before toolchain tests — `just test` enforces that order.

## Spoke Index

- [README](README) — project overview, installation, and usage
- [MIR docs](packages/compiler/MIR.md) — upstream MIR/c2mir reference
