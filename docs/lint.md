# Lint

`mc lint` (`src/lint/lint.zig`) runs a syntax gate followed by clang-tidy,
and reformats its diagnostics.

## Default checks

```
-*, bugprone-*, clang-analyzer-*, readability-*,
-bugprone-easily-swappable-parameters, -readability-identifier-length
```

Overridable via the `[lint]` section in `mc.toml`; falls back to the
defaults above when unset.

## Usage

```sh
mc lint [--syntax-only] file.c
```

- Exit code `0` on clean, `1` on issues found or if `clang-tidy` is
  missing.
- `--syntax-only` skips the clang-tidy pass and only runs the syntax gate.
- Via `just`: `just lint <file>` (requires `just build` first).

## Notes

- Diagnostic formatting is adapted from DonIsaac/zlint's `src/Error.zig`
  (MIT), reworked for C/clang-tidy output.
- `lint.zig` depends on `fmt.zig`'s `findTool` to locate `clang-tidy`
  (`.exe` appended on Windows).
