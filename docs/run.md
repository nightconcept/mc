# Run command

`mc run` (and bare `mc file.c`) compiles and JIT-executes a C source via
tcc's `-run`, without writing an artifact to disk — the immediate-execution
counterpart to `mc build` (see [Build command](build.md)).

## Usage

```sh
mc file.c [args]          # shorthand: implicit run
mc run file.c -- [args]   # explicit form
```

- Bare invocation (`mc file.c`) and `mc run file.c` route to the same path
  in `route()` (`src/cli/mc.zig`): both prepend `-run <file>` before
  forwarding to tcc.
- The explicit form's `--` marks the end of `mc`-consumed arguments;
  everything after it is forwarded to the program being run, not to tcc.
  The shorthand form has no `--`: all args after the source file are
  forwarded as run-time arguments.

## Notes

- Requires the embedded TinyCC runtime cache, extracted lazily on first
  use — see `prepareRuntime()` in `src/cli/mc.zig` and
  `docs/architecture.md`.
- `mc tcc [args]` bypasses this routing entirely and forwards straight to
  the raw tcc driver (still with `-B<cache>` prepended) — use it for flags
  `run`/`build` don't cover.
