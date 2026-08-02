# Build command

`mc build` compiles a C source into an artifact — the ahead-of-time
counterpart to `mc run` (see [Run command](run.md)). This is the
`mc` CLI subcommand; for building the `mc` tool itself, see
[Development build](development.md).

## Usage

Two modes, chosen by whether any args follow `build`:

```sh
mc build                       # project mode: reads mc.toml, no args
mc build --locked              # project mode; require the checked-in lock
mc build [args]                 # passthrough mode: raw tcc args
```

### Project mode (`mc build`, no args)

Reads `mc.toml` (found by walking up from cwd, same as `mc fmt`/`mc lint`)
and compiles a project without needing any tcc flags:

- `build.sources` — array of paths/patterns (default: recursively collect
  `*.c` under `src/`). A pattern containing `*` walks the directory before
  the first `*` recursively, keeping files with the pattern's suffix
  (usually `.c`) — this is not full glob syntax, just enough to let a
  project pick one source file over another explicitly (see "Notes" below).
- `build.main` — explicit path to the file that owns `main()`. Only needed
  when the resolved `sources` would otherwise contain more than one file
  defining `main()`; skips the auto-detection guard entirely.
- `build.target` — output binary path (default: `bin/<project.name>`,
  `.exe` appended on Windows).
- `build.include_dirs` / `build.defines` — `-I`/`-D` flags, same as the
  `[fmt]`/`[lint]` sections' use of `mc.toml`.
- `build.lib_dirs` / `build.libs` — `-L`/`-l` flags, for linking a vendored
  library (default `lib_dirs`: `lib/`, if that directory exists). On PE
  (Windows), tcc's `-l<name>` resolves directly against `<name>.dll`/
  `lib<name>.dll` (or a `.def`) in a `-L` dir — no import `.lib` needed;
  elsewhere it resolves the usual `lib<name>.a`/`.so`.

`mc init` scaffolds `src/main.c` and a clean `mc.toml`.

## Applications and packages

Existing manifests are applications: `project.kind` defaults to
`"application"`. An application supplies the one `main()` and may declare
full Git URLs at the TOML root:

```toml
dependencies = ["https://github.com/acme/mc-json"]

[project]
name = "notes"
```

Run `mc add <git-url>` to validate and lock a dependency, or `mc update`
to refresh it. An optional `#tag` or `#commit` fragment is resolved by Git.
`mc.lock` is generated, must be committed, and pins an exact commit plus a
SHA-256 archive hash. Builds consume only this lock; they do not advance a
remote branch. `mc build` reports a missing or stale lock, and
`mc build --locked` is the CI spelling of the same reproducible contract.

A reusable package is initialized with:

```sh
mc init --package https://github.com/acme/mc-json
```

It writes `kind = "package"`, creates `src/` and
`include/mc-json/`, and does not create `src/main.c`. Packages cannot be
built alone and cannot define `main()`. Their configured C sources compile
with the consuming application. `include/` is the package's exported C
header root, not a `node_modules` directory: if the package contains
`include/mc-json/json.h`, consumers write `#include <mc-json/json.h>`.

GitHub and Forgejo need no special configuration: both are ordinary Git URL
hosts. Checkouts live in a disposable shared platform cache under
`mc/packages/` (or `MC_PACKAGE_CACHE_DIR` for an explicit override), never
in a project-local vendor directory.

### Passthrough mode (`mc build <args>`)

`build` (like `tcc`) passes its arguments straight through to the tcc
driver unmodified — only the embedded runtime's `-B<cache>` flag is
prepended (see `route()` in `src/cli/mc.zig`). Standard tcc flags apply:

```sh
mc build -c file.c -o file.o   # compile to object
mc build -S file.c             # compile to assembly
mc build file.c -o file         # compile + link an executable
```

## Notes

- Unlike `mc run`/bare invocation, `build` does not add `-run` — it
  produces an artifact on disk rather than JIT-executing.
- The embedded TinyCC runtime cache is extracted lazily on first use to
  `%LOCALAPPDATA%\mc\...` (Windows) or the XDG-equivalent elsewhere — see
  `prepareRuntime()` in `src/cli/mc.zig` and `docs/architecture.md`.
- Project mode hard-errors if more than one resolved source file defines a
  top-level `main()` (a real-world C tree often has an example/tool/test
  main alongside the primary one) — narrow `build.sources` or set
  `build.main` rather than letting tcc's linker report a duplicate symbol.
  Convention over configuration: the common single-`main()` case needs no
  `[build]` section at all.
