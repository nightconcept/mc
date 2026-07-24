# Conventions

## Commits

Follow [Conventional Commits](https://www.conventionalcommits.org/):
`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, `style:`.

Keep TinyCC updates (`just update-tinycc`) as their own commit, separate
from `mc`-side changes — the two evolve independently and are easier to
review/bisect apart.

## Code style

- Match surrounding code; avoid unrelated formatting changes in the same
  diff as a functional change.
- Zig sources are formatted with `just fmt` (see `docs/fmt.md` for the
  distinction from `mc fmt`, which formats target C/H files).
- C sources under test fixtures/examples follow the `mc fmt` default style
  (LLVM-based, 120 columns, 4-space indent) unless a local `.clang-format`
  says otherwise.

## Testing discipline

Run the smallest relevant test suite before committing — see
`docs/testing.md`. Legacy tests always gate before toolchain tests;
`just test` enforces that order.

## Tool pins

Toolchain versions (`zig`, `python`, `just`, `lefthook`) are pinned in
`mise.toml`. Update pins deliberately, not as a side effect of an
unrelated change.
