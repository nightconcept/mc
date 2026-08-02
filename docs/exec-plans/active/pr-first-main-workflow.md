# Execution Plan: PR-first Main Workflow

Status: active
Last reviewed: 2026-08-01
Owner: nightconcept

**Research:** `docs/repo/pr-first-workflow.md`
**Issue/Ref:** User-requested workflow migration, 2026-08-01

## Goal

Make `main` the sole, simple integration branch. All work reaches it through a
pull request whose Linux, macOS, and Windows CI checks pass. Retire `dev` as a
branch and as branch-specific workflow terminology while preserving the
post-merge `edge` pre-release.

## Worker Context Bootstrap

Every worker must first read:

1. `AGENTS.md`
2. `docs/repo/index.md`
3. `docs/repo/pr-first-workflow.md`
4. `.github/workflows/mc.yml`

## Approach

Use GitHub protection as the enforcement mechanism and the workflow file as
the validator. Create `main` from the current `dev` tip, make it the default,
and configure its protection before retiring `dev`. Keep one CI workflow:
pull-request runs validate changes; `main` push runs validate the merged commit
and then publishes `edge`. This preserves the current release behavior without
granting pull requests write permissions.

## Phases

### Phase 1: Establish and protect `main`

**Objective:** Create `main` at the current `dev` commit and make GitHub refuse
unreviewed or failing changes to it.
**Depends on:** none
**Files to change:** None; this phase changes GitHub repository settings.

**Implementation notes:**

- Create `main` from the verified current `dev` tip and push it.
- Change the repository default branch to `main`.
- Add a GitHub ruleset (preferred) or branch-protection rule targeting `main`.
  Require a pull request, the `linux-x64`, `macos-arm64`, and `windows-x64`
  checks, and an up-to-date branch before merge. Disallow direct pushes and
  all bypasses, including administrators.
- Require no approving review initially. This makes the pull request and CI
  mandatory without blocking a solo maintainer; add a one-review requirement
  later if the contributor model changes. Enable automatic deletion of merged
  topic branches.

**Verification:**
```bash
gh api repos/nightconcept/mc --jq '.default_branch'
gh api repos/nightconcept/mc/rulesets
gh workflow run CI --ref main
gh run list --branch main --workflow CI --limit 1
```

**Status:** [ ] not started

---

### Phase 2: Make CI `main`-only and keep releases post-merge

**Objective:** Validate pull requests into `main` and publish `edge` only from
a successful `main` push.
**Depends on:** Phase 1
**Files to change:**

- `.github/workflows/mc.yml` — limit `push` and `pull_request` branch filters
  to `main`; change the release guard from `dev` to `main`.

**Implementation notes:**

- Keep the three existing job names unchanged because the ruleset requires
  those exact checks.
- Do not add write permissions to validation jobs. The release job alone keeps
  `contents: write` and remains gated by all platform jobs plus a `main` push.
- A workflow-file pull request will exercise the new PR trigger; after merging,
  inspect the `main` push run and its `edge` release.

**Verification:**
```bash
gh workflow view CI --yaml
gh pr checks <migration-pr-number> --watch
gh run list --branch main --workflow CI --limit 1
gh release view edge
```

**Status:** [ ] not started

---

### Phase 3: Publish the working agreement and retire `dev`

**Objective:** Make the PR workflow the repository default and remove the
retired branch only after the protected path has worked.
**Depends on:** Phase 2
**Files to change:**

- `AGENTS.md` — add compact PR-first branch guidance and replace branch-specific
  `dev` language while retaining the 100-line limit.
- `docs/conventions.md` — document topic branch, PR, CI, merge, and cleanup
  expectations.
- `README.md` — replace ambiguous developer-workflow wording where needed.
- `scripts/dev.py` — delete the unused backward-compatibility shim after
  confirming no supported invocation depends on it.
- `docs/TASKS.md` — check off and log the completed workflow item.

**Implementation notes:**

- State the normal loop precisely: sync `main`; create `type/short-name`;
  make a conventional commit; run the smallest relevant local test; open a PR
  to `main`; wait for required CI; merge; delete the topic branch.
- Do not treat generic phrases such as "development build" as branch references.
- Delete remote `dev` only after a real PR has merged to protected `main`, CI
  has passed, and the `edge` release has updated from `main`.
- Update local clones with `git remote set-head origin --auto` after deletion.

**Verification:**
```bash
rg -n -i 'refs/heads/dev|branches: \[.*dev|origin/dev|\bdev branch\b' .github AGENTS.md README.md docs scripts
git ls-remote --symref origin HEAD
git ls-remote --heads origin main dev
```

**Status:** [ ] not started

## Testing Strategy

GitHub is the integration test surface. Verify a migration pull request runs
all three platform jobs; verify GitHub blocks merge until each required check
passes; merge it through the PR UI; then verify the `main` push produces the
same three checks and refreshes `edge`. Local changes to the workflow require
no compiler test changes, but the existing `just ci` in every job continues to
test build, legacy, toolchain, and packaging behavior.

## Rollout / Integration Notes

Phase 1 must precede the CI change so `main` exists and has observable check
names. Do not delete `dev` while it is the default branch. The migration change
itself should be a PR to `main`; once merged, `dev` can be deleted.

## Known Risks

- Required-check names can drift if job names change. Keep the names stable or
  update the ruleset in the same controlled change.
- The `edge` release will move from the last `dev` commit to the first merged
  `main` commit. Confirm that this is the intended release source.

## Out of Scope

- Versioned/stable release policy and release-note automation.
- Changes to compiler code, test content, or toolchain dependencies.
- Rewriting ordinary prose that uses "development" without referring to the
  retired `dev` branch.

## Progress Log

- 2026-08-01: Plan created from current GitHub and repository workflow
  research; no implementation started.
