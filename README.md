# ModC (mc)

ModC is a monorepo for a modern C toolchain. `mc` is a Zig-built CLI
frontend (`src/cli/mc.zig`) backed by [TinyCC](https://github.com/nightconcept/tinycc)
(configured via `build.zig.zon`) and first-party toolchain subpackages
(`fmt`, `lint`, `lsp`, `toml`) located in `src/`.

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
mc run file.c -- [args]       # compile and run (JIT via tcc)
mc build                      # build the mc.toml project (reads [build])
mc build [args]               # build artifact (-c/-S/-o, ...)
mc lint [--syntax-only] file  # lint (syntax gate + clang-tidy)
mc fmt [--check] [files|.]    # format with clang-format
mc lsp                        # start LSP server (clangd bridge)
mc init                       # scaffold mc.toml in current directory
mc tcc [args...]              # pass args straight through to tcc driver
```

## Development

All repository tasks go through `just` (see `justfile`):

```sh
just build           # out-of-tree build into build/
just test-legacy     # vendored upstream TinyCC tests2 suite
just test-toolchain  # mc CLI tests (not compilation)
just test            # both, legacy first
just package         # copy build/mc into dist/
just gate-fast       # fmt + zig unit tests (pre-commit; needs a prior `just build`)
just gate            # gate-fast + build + full test suite (pre-push)
```

To update the TinyCC dependency to the latest commit on its `mc` branch:

```sh
just update-tinycc
```

## License

The mc project is dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
