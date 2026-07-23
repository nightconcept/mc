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

## Essential Commands

- **Tools**: `mise install` (zig, python, just, lefthook), then `just hooks-install`
- **Gate**: `just gate-fast` (fmt + zig unit tests, runs pre-commit — needs one
  prior `just build` since `mc.zig` embeds the compiled tcc runtime archive)
  or `just gate` (adds build + legacy + toolchain tests, runs pre-push)
- **Build**: `just build` — out-of-tree build into `build/` (objects, libs,
  `tcc`, `mc`); repo root and `src/` stay clean
- **Test legacy (vendored upstream TinyCC tests2 suite)**: `just test-legacy`
- **Test toolchain (mc CLI, not compilation)**: `just test-toolchain`
- **Test both, legacy first**: `just test`
- **Package**: `just package` — copies `build/mc` into `dist/`
- **Format Zig**: `just fmt`
- **Lint C**: `./build/mc lint <file.c>` after `just build`
- **Update TinyCC**: push to nightconcept/tinycc `mtc` branch, then
  `just update-tinycc`

## Engineering Standards

- Match surrounding code and avoid unrelated formatting changes.
- Keep TinyCC updates (via `just update-tinycc`) as their own commit,
  separate from `mc`-side changes.
- Commits **must** follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
- Run the smallest relevant test before committing; use `just test-legacy` for
  compiler changes and `just test-toolchain` for `mc` CLI changes. Legacy
  tests always gate before toolchain tests — `just test` enforces that order.

## Spoke Index

- [README](README.md) — project overview, installation, and usage
- [TinyCC docs](https://github.com/nightconcept/tinycc/blob/mtc/tcc-doc.texi) — upstream TinyCC reference
