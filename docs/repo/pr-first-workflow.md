# PR-first Workflow Research

Status: active
Last reviewed: 2026-08-01
Owner: nightconcept

## Current state

- The GitHub default branch, remote `HEAD`, and local checkout are `dev`.
- The remote has no `main` branch. It has no rulesets, and `dev` has no branch
  protection. Direct pushes are therefore permitted.
- [`.github/workflows/mc.yml`](../../.github/workflows/mc.yml) runs `just ci`
  for pull requests and pushes to both `dev` and `main`. Its three check names
  are `linux-x64`, `macos-arm64`, and `windows-x64`.
- A `push` to `dev` currently replaces the moving `edge` pre-release. See the
  `release` job in [the CI workflow](../../.github/workflows/mc.yml).
- There is no documented branch or pull-request policy in
  [AGENTS.md](../../AGENTS.md) or [the conventions](../conventions.md).

## Implications

Workflow triggers run validation but do not restrict a push or merge. GitHub
must enforce PR-only movement with a ruleset or branch-protection rule that
requires the CI checks. GitHub documents the relevant controls in
[Managing protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches)
and [About rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets).

`main` must be created and made the default branch before `dev` can be
deleted. Required checks should be selected only after they have run against
`main`, so GitHub can identify their exact names.

## Proposed policy

`main` is the sole integration branch. Every repository change starts from a
short-lived topic branch, is validated by a pull request to `main`, and reaches
`main` only through the protected merge path. Post-merge CI may publish the
existing moving `edge` pre-release from `main`; pull-request CI must never
publish it.

The word `dev` should no longer describe the integration branch. Existing
generic uses such as "development build" should be retained where they do not
refer to the retired branch. The unused compatibility shim
`scripts/dev.py` requires an explicit remove-or-rename decision during the
migration.
