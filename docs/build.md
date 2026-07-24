# Build command

`mc build` compiles a C source into an artifact — the ahead-of-time
counterpart to `mc run` (see [Run command](run.md)). This is the
`mc` CLI subcommand; for building the `mc` tool itself, see
[Development build](development.md).

## Usage

```sh
mc build [args]
```

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
