# Development Build

Building the `mc` tool itself from source (`just build` et al). This is
distinct from the `mc build`/`mc run` CLI commands, which compile a
*user's* C file with the already-built `mc` — see
[Build command](build.md) and [Run command](run.md) for those.

## Commands

- `just build` — runs `scripts/build.py`: self-compiles the TinyCC runtime
  for the host target, then builds `src/cli/mc.zig` into `build/mc` (out of
  tree; repo root and `src/` stay clean). Uses `-mcpu=native` — fastest on
  the machine that built it, not portable off it.
- `just build-portable` — same build with `--cpu baseline`, producing a
  binary that runs on any CPU of the target architecture. This is what
  `just ci` uses for the published release artifacts.
- `just clean` — removes `build/`, `dist/`, `.mccache`, `.zig-cache`,
  `zig-out`
- `just package` — runs `scripts/package.py`, copies `build/mc` into `dist/`.
  Refuses a `-mcpu=native` build; override with `MC_PACKAGE_ALLOW_NATIVE=1`
  if you deliberately want a host-only binary in `dist/`.
- `just fetch-tools [version]` — installs the Zig toolchain via
  `scripts/fetch_tools.py` (default version `22`)
- `just check` — `zig build check` (typecheck without emitting binaries)
- `just ci` — `build-portable` + `test` + `package`, the full CI sequence

## Notes

- Every build path needs at least one prior `just build`: `mc.zig` embeds
  the compiled tcc runtime archive (`build/mc-runtime.tar`) as a Zig
  module, so even `zig build check`/unit tests fail without it.
- `scripts/build.py` is target-aware (Linux/macOS/Windows,
  x86_64/arm64) — see `docs/architecture.md` for how the runtime is
  assembled and embedded.
- Updating the TinyCC dependency is a separate step from a normal build:
  push to nightconcept/tinycc's `mc` branch, then run `just update-tinycc`
  to re-pin `build.zig.zon`. Keep that as its own commit, separate from
  `mc`-side changes.
