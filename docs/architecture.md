# Architecture

## Layout

- Root — workspace tooling only: `justfile`, `mise.toml`, `build.zig`,
  `build.zig.zon`, `scripts/`, `tests/`
- `src/cli/mc.zig` — the `mc` frontend: parses the subcommand and dispatches
  to the matching package, or falls through to the raw `tcc` driver
- `src/fmt/format.zig` — `mc fmt` (clang-format wrapper)
- `src/lint/lint.zig` — `mc lint` (clang-tidy wrapper)
- `src/lsp/lsp.zig` — `mc lsp` (clangd bridge)
- `src/toml/toml.zig` — `mc.toml` config parsing, shared by fmt/lint
- `src/packages/packages.zig` — package manifests, URL Git resolution,
  shared immutable checkout cache, `mc.lock`, and resolved C source graphs
- `build/` — out-of-tree build output (objects, libs, `tcc`, `mc`); repo
  root and `src/` stay clean
- `dist/` — packaged output from `just package`

## TinyCC dependency

TinyCC is not vendored in this repo. `build.zig.zon` pins a commit on
nightconcept/tinycc's `mc` branch, fetched into the Zig global package
cache. `just update-tinycc` pushes local tcc changes to that branch and
re-pins the fetched revision.

## Runtime embedding

`mc` statically embeds a compiled TinyCC runtime (`libtcc1.a` + headers,
tarred as `mc-runtime.tar`) so a plain `mc` binary can compile/run C without
a separate install step. `scripts/build.py` self-compiles this runtime
per-target (Linux/macOS/Windows, x86_64/arm64) before building `mc.zig`,
which is why every build path needs one `just build` before Zig unit tests
can link (`mc.zig` imports the runtime archive as a Zig module).

At runtime, `mc` extracts the embedded tarball to a per-version/arch/os
cache directory (`%LOCALAPPDATA%\mc\...` on Windows, XDG-equivalent
elsewhere), gated by a `.complete` marker.

Windows (PE) has several build-time pitfalls that don't apply on
Linux/macOS (headers, lib layout, missing libm) — see the Windows-specific
comments in `scripts/build.py` if you're touching that path.

## Package boundaries

Each `src/<name>/` package is a separate Zig module wired together via
`--dep`/`-M` flags in `build.zig` and in `tests/test_toolchain.py`'s
`zig_unit_tests()`. When adding a new package, wire it in both places.

## URL packages

`src/packages/` keeps package acquisition outside the CLI and compiler. It
accepts full Git URLs for any host, resolves mutable refs only for `mc add`
and `mc update`, and records commit IDs plus SHA-256 source-archive hashes in
the committed `mc.lock`. Builds read that lock and use immutable checkouts in
the platform cache (`MC_PACKAGE_CACHE_DIR` overrides it). The resolver returns
only source files and exported include roots to `mc build` and `mc lsp`.
