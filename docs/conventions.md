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

## Branch workflow

`main` is the only integration branch. Start every change from current `main`
on a short-lived topic branch such as `feat/format-rules` or `fix/windows-lib`.
Make conventional commits, run the smallest relevant local check, then open a
pull request to `main`.

The pull request must pass the required Linux, macOS, and Windows CI checks
before it merges. Do not push directly to `main`. Delete the topic branch after
the pull request merges.

## Tool pins

Toolchain versions (`zig`, `python`, `just`, `lefthook`) are pinned in
`mise.toml`. Update pins deliberately, not as a side effect of an
unrelated change.
