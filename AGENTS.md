# ⚠ This file is hard-limited to ≤100 lines. Update spokes, not the hub.

# ModC (mc) Agent Guide

## Intent

Maintain the ModC compiler toolchain with small, reviewable changes. The
compiler is a thin `mc` frontend (Zig) around MIR/c2mir; future packages
(linter, formatter, LSP) live under `src/`.

## Stack

- Monorepo: `src/<name>/` holds each first-party package; root is workspace
  tooling only (`justfile`, `mise.toml`, `scripts/`)
- `src/cli/mc.zig` — the `mc` CLI frontend
- `build.zig.zon` — declares the MIR dep (nightconcept/mir `mc` branch,
  pinned to a commit hash; update with `just update-mir <sha>`)
- MIR sources live in the Zig global package cache (not in the repo)
- `scripts/` — build/test/package CLI, driven via `just` (tools pinned in `mise.toml`)

## Essential Commands

- **Tools**: `mise install` (zig, python, just, lefthook), then `just hooks-install`
- **Gate**: `just gate-fast` (fmt + zig unit tests, runs pre-commit) or
  `just gate` (adds build + legacy + toolchain tests, runs pre-push)
- **Build**: `just build` — out-of-tree build into `build/` (objects, libs,
  `c2m`, `mc`); repo root and `src/` stay clean
- **Test legacy (upstream MIR c-tests suite)**: `just test-legacy`
- **Test toolchain (mc CLI, not compilation)**: `just test-toolchain`
- **Test both, legacy first**: `just test`
- **Package**: `just package` — copies `build/mc` into `dist/`
- **Format Zig**: `zig fmt src/cli/mc.zig`
- **Lint C**: `./build/mc lint <file.c>` after `just build`
- **Update MIR**: push to nightconcept/mir `mc` branch, then
  `just update-mir <new-commit-sha>`

## Engineering Standards

- Match surrounding code and avoid unrelated formatting changes.
- Keep MIR updates (via `just update-mir`) as their own commit, separate
  from `mc`-side changes.
- Commits **must** follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
- Run the smallest relevant test before committing; use `just test-legacy` for
  compiler changes and `just test-toolchain` for `mc` CLI changes. Legacy
  tests always gate before toolchain tests — `just test` enforces that order.

## Spoke Index

- [README](README) — project overview, installation, and usage
- [MIR docs](https://github.com/nightconcept/mir/blob/mc/MIR.md) — upstream MIR/c2mir reference
