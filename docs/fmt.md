# Format

`mc fmt` (`src/fmt/format.zig`) formats `.c`/`.h` files with clang-format.

## Style resolution order

1. `[fmt]` section in `mc.toml`, if present, builds a clang-format style
   string at runtime.
2. Otherwise, a `.clang-format` file in the project root is used as-is.
3. Otherwise, the built-in default: `BasedOnStyle: LLVM, ColumnLimit: 120,
   IndentWidth: 4, UseTab: Never, PointerAlignment: Right,
   BreakBeforeBraces: Attach, AllowShortFunctionsOnASingleLine: Inline,
   AlignConsecutiveMacros: Consecutive, SortIncludes: Never,
   IncludeBlocks: Preserve`.

## Usage

```sh
mc fmt [--check] [files|.]
```

- `--check` exits 1 if any file would be reformatted, without writing —
  used by `just gate`/`gate-fast` and CI.
- `.` formats all `.c`/`.h` files under the current directory.

## Zig source formatting

This is separate from `mc fmt` (which formats target C/H files). The
toolchain's own Zig sources are formatted via:

```sh
just fmt         # zig fmt src/cli/mc.zig src/fmt/format.zig src/lint/lint.zig src/lsp/lsp.zig build.zig
just fmt-check   # same, --check mode
```

`findTool` in `src/fmt/format.zig` locates `clang-format` on `PATH`,
appending `.exe` on Windows.
