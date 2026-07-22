# ModC (mc)

ModC is a monorepo for a modern C toolchain. `mc` is a Zig-built CLI
frontend (`packages/cli/mc.zig`) around a vendored copy of
[MIR/c2mir](https://github.com/vnmakarov/mir), the MIR project's
C-to-MIR compiler.

## Quick start

```sh
mise install
just hooks-install
just build
./build/mc hello.c
```

## Usage

Run a C file directly:

```sh
mc hello.c
```

Or route to an explicit subcommand:

```sh
mc run <file.c>     # compile and run
mc build <file.c>   # compile to an executable
mc lint <file.c>    # static checks, no build
mc c2m [args...]    # pass args straight through to the c2mir driver
```

## Development

All dev tasks go through `just` (see `justfile`):

```sh
just build           # out-of-tree build into build/
just test-legacy     # vendored upstream MIR c-tests suite
just test-toolchain  # mc CLI tests (not compilation)
just test            # both, legacy first
just package         # copy build/mc into dist/
just gate-fast       # fmt + zig unit tests (pre-commit)
just gate            # gate-fast + build + full test suite (pre-push)
```

To update the compiler submodule to the latest commit:

```sh
just update-compiler
```

## License

The mc project is dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
