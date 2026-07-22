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
- `packages/compiler/` — git submodule tracking https://github.com/vnmakarov/mir
  (C-to-MIR compiler, c2mir)
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
- **Update compiler submodule**: `just update-compiler`

## Engineering Standards

- Match surrounding code and avoid unrelated formatting changes.
- Keep `packages/compiler` submodule updates as their own commit (via
  `just update-compiler`), separate from `mc`-side changes.
- Commits **must** follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
- Run the smallest relevant test before committing; use `just test-legacy` for
  compiler changes and `just test-toolchain` for `mc` CLI changes. Legacy
  tests always gate before toolchain tests — `just test` enforces that order.

## Spoke Index

- [README](README) — project overview, installation, and usage
- [MIR docs](packages/compiler/MIR.md) — upstream MIR/c2mir reference
