# Plan: URL-sourced C packages — completion plan

**ID:** 001  
**Created:** 2026-08-01  
**Research:** `docs/research/001-mc-packages.md`  
**Issue/Ref:** User design discussion, 2026-08-01  
**Status:** ready; supersedes the uncommitted prototype

## Goal

Extend `mc.toml` so a project is either an application (the backwards-compatible
default) or a reusable C package. Applications declare dependencies as full Git
URLs, for GitHub and Forgejo alike. `mc` resolves those URLs to immutable source
snapshots in a generated, committed `mc.lock`, then compiles package sources with
the application. A package exports its C interface through its own `include/`
layout; dependency URLs never create aliases or rewrite `#include` paths.

## Completion checklist

- [x] Finish and validate the manifest model: application/package rules, root
  dependency arrays, package scaffolding, and safe relative paths.
- [x] Implement the lock-only resolved source graph: deterministic transitive
  order, public headers, package-private includes, `main()` and cycle checks.
- [x] Implement Git acquisition: URL/ref parsing, shared immutable cache,
  atomic fetch publication, canonical lockfile, and content verification.
- [x] Implement `mc add`, `mc update`, and `mc build --locked`, including
  selective updates and no-write failure behavior.
- [x] Integrate dependency flags into `mc build` and `mc lsp`; document the
  public interface and lock/cache lifecycle.
- [x] Finish TDD coverage, run the complete quality gate, review the final
  diff to a fixed point, update task records, and commit the feature.

## Current Implementation Status

An uncommitted TDD spike added `mc init --package` and a direct `file://`
dependency test. Review found it is not safe to land: it stores clones in a
project-local cache, does not consume or verify the lockfile, lacks a content
hash, supports one direct dependency only, and advertises an unimplemented
`mc update`. Phase 0 removes that spike and its corresponding docs/tests before
the implementation begins. Do not preserve its interfaces.

## Worker Context Bootstrap

Every worker agent must execute these reads at session start, before any
implementation:

1. Read `AGENTS.md` — repository intent, commands, and progress-log rule.
2. Read `docs/architecture.md` — current source-module map and runtime cache.
3. Read `docs/conventions.md` and `docs/testing.md` — code and verification rules.
4. Read `docs/research/001-mc-packages.md` — accepted package model and precedents.
5. Read this plan and the files named in the phase being implemented.

Do not proceed to implementation until these files are loaded.

## Approach

Use a source-package model: a package declares reusable sources and public
include roots; an application supplies the only `main()` and final linker
settings. This avoids prebuilt-library ABI and target problems in TinyCC.

Keep dependency declarations as a root string array (`dependencies = [URL]`).
The shared TOML adapter already exposes string arrays, so this is intentionally
smaller and more robust than adding TOML inline-table support merely to create
aliases. The URL is acquisition data only. The contents of a fetched package's
`include/` directory decide whether its consumer writes
`#include <mc-json/json.h>`.

Put manifest loading, package-graph resolution, cache addressing, and Git
interaction behind a new `src/packages/` module. Its interface returns a
validated resolved source graph (source paths, private compilation flags, and
exported include roots) to the CLI. That is a deep module: callers do not know
about URL fragments, `git`, lockfile format, cache layout, or transitive graph
traversal. The CLI remains responsible for command routing and constructing the
final TinyCC argument vector.

The first release supports only full Git URLs, including arbitrary Forgejo
hosts. A fragment is either a Git tag or commit. A URL with no fragment resolves
the remote's default-branch tip *only* during `mc add` or `mc update`; normal
builds use `mc.lock`. There is no `mc vendor`, registry, package alias, semver
range, package binary distribution, or local-path dependency in this scope.

## Phases

### Phase 0: Remove the rejected prototype

**Objective:** Return the worktree to the pre-package implementation state so
the feature is introduced through the planned module seam rather than growing
inside `src/cli/mc.zig`.

**Depends on:** none

**Files to change:**

- `src/cli/mc.zig` — remove uncommitted `add`/`update`/package-init/cache/lock
  helpers and restore the original CLI routing/build signature.
- `src/toml/toml.zig` — remove the uncommitted root-table representation change;
  Phase 1 replaces it with an intentional manifest interface and tests.
- `tests/test_toolchain.py` — remove spike-only tests; Phase 1 reintroduces
  them from public CLI seams with the complete contract.
- `docs/build.md` — remove documentation that claims the rejected cache and
  lock behavior are available.

**Implementation notes:**

- Use `apply_patch`, not `git checkout`/`git reset`, because the worktree is
  shared and may contain unrelated changes.
- Retain `docs/research/001-mc-packages.md` and this plan; they are deliberate
  planning artifacts, not spike code.
- Confirm the only remaining changes are those two planning documents before
  starting Phase 1.

**Verification:**

```bash
git diff --check
just build
python3 tests/test_toolchain.py --unit-only
```

**Status:** [x] complete

---

### Phase 1: Package manifest and project-kind rules

**Objective:** Establish the application/package distinction without changing
the behavior of existing application manifests.

**Depends on:** Phase 0

**Files to change:**

- `src/packages/packages.zig` — add a manifest reader/validator with the public
  types for project kind, package source roots, public include roots, and URL
  dependency strings.
- `src/cli/mc.zig` — replace direct `[project]`/`[build]` reads with the
  manifest reader; retain application output behavior, and give a package-root
  `mc build` a clear error that packages are built by a consuming application.
- `src/toml/toml.zig` — add focused parser tests for the root string-array
  dependency form if required by the package manifest reader; do not add inline
  table support.
- `scripts/build.py` — wire the new `packages` Zig module into the executable.
- `tests/test_toolchain.py` — add manifest and CLI smoke coverage for an
  omitted/explicit `kind = "application"`, a valid package manifest, invalid
  kinds, and application-only `main()` enforcement.
- `docs/build.md` — document `project.kind`, package build semantics, and the
  fact that existing manifests remain applications.

**Implementation notes:**

- Accepted values are exactly `application` and `package`; omitted means
  `application`.
- An application uses existing `[build]` defaults and must still resolve one
  root `main()` (or use `build.main`).
- A package requires `[package]`; `package.sources` defaults to `src/**/*.c`
  and `package.include_dirs` defaults to `include/` when it exists. Its own
  sources must not define `main()`.
- Validate all user paths with the existing relative-path convention. Reject
  absolute paths and paths escaping the package root before compiling them.
- Preserve `build.outputs` and passthrough `mc build <args>` behavior.
- Give the resolver a concrete, narrow interface before wiring it to the CLI:
  `loadRoot`, `resolveLockedGraph`, `add`, and `update`. It owns parsed
  manifests, URL/ref values, lock entries, cache paths, and Git process calls;
  it returns only resolved source/include paths plus diagnostics to the CLI.

**Verification:**

```bash
just build
just test-toolchain
```

**Status:** [x] complete

---

### Phase 2: Resolve and compile locked source packages

**Objective:** Make an application compile against a resolved package graph and
propagate each package's public headers without aliases.

**Depends on:** Phase 1

**Files to change:**

- `src/packages/packages.zig` — implement recursive package-manifest loading,
  cycle detection, deterministic dependency order, source collection, and
  separation of a package's private versus exported include roots.
- `src/cli/mc.zig` — obtain a resolved graph before `buildOne`; append all
  package sources before root sources and add exported `-I` roots to the final
  TinyCC invocation.
- `src/lsp/lsp.zig` — use the same resolver output when emitting
  `.mccache/compile_commands.json`, so clangd sees dependency headers.
- `tests/test_toolchain.py` — create a package fixture whose
  `include/mc-json/json.h` is consumed as `<mc-json/json.h>`; assert a consumer
  builds/runs, package sources cannot contain `main()`, a missing public header
  fails normally, and cycles report the full URL chain.
- `docs/build.md` — explain source-level dependency compilation and the public
  header contract.

**Implementation notes:**

- Phase 2 consumes an already-resolved dependency root supplied by the lock
  reader; it must not run Git or write project files. Keep this module
  deterministic and independently unit-testable.
- Source order is deterministic depth-first postorder: a package's own
  dependencies, then its sources, then the application sources. This preserves
  static-link ordering if a future compilation path emits archives.
- Add only exported `package.include_dirs` to a consumer. A package's private
  include roots are present solely while compiling that package's own sources.
- Do not interpret URL/repository names as an include prefix. `-I` points at
  the package's actual `include/` directory.
- Refactor shared source expansion out of the CLI only if necessary; retain its
  current limited `**/*.c` semantics so project behavior does not drift.

**Verification:**

```bash
just build
just test-toolchain
```

**Status:** [x] complete

---

### Phase 3: Git cache, lockfile, and locked builds

**Objective:** Resolve full Git URLs into a shared cache and make builds
reproducible through `mc.lock`.

**Depends on:** Phase 2

**Files to change:**

- `src/packages/packages.zig` — add Git URL validation, fragment parsing,
  default-branch/tag/commit resolution, immutable checkout cache management,
  canonical lockfile encode/decode, content hashing, and `--locked` checks.
- `src/cli/mc.zig` — pass environment/cache configuration to the resolver,
  accept `mc build --locked`, and make a regular build fail with an actionable
  instruction when dependencies lack a matching lock entry.
- `tests/test_toolchain.py` — build temporary bare Git repositories via
  `file://` URLs; test default-branch resolution, tag and commit fragments,
  transitive dependencies, unchanged locked builds after the remote advances,
  hash/revision mismatch failure, and `--locked` refusing a stale/missing lock.
- `docs/build.md` — document dependency cache behavior, `mc.lock`, and
  reproducible build guarantees.
- `.gitignore` — ignore only any project-local test/cache artifacts actually
  introduced; never ignore `mc.lock`.

**Implementation notes:**

- Reuse the platform cache conventions in `cachePathFor`; use
  `MC_PACKAGE_CACHE_DIR` as an explicit override and otherwise place package
  checkouts under the platform cache's `mc/packages/` subtree.
- Use `std.process.spawn` with an argv array—never a shell—to invoke `git`.
  Accept HTTPS, SSH, and `file://` URLs. GitHub and Forgejo are first-class by
  being ordinary full Git URLs; no GitHub API, Forgejo API, or forge-specific
  code is required.
- A bare URL resolves `HEAD` once during mutation. `#fragment` resolves a Git
  tag or commit. Record the full commit object ID and a deterministic SHA-256
  tree/content hash. Reject a lock whose URL, revision, or hash does not match
  the checkout.
- Write a stable TOML lockfile sorted by URL. Build reads only the lockfile;
  only `add` and `update` move a dependency forward.
- Add a cache lock or atomic temporary-directory rename before exposing a
  checkout, since the existing runtime cache explicitly notes a first-run
  race and dependencies are more likely to be fetched concurrently.

**Verification:**

```bash
just build
just test-toolchain
just gate-fast
```

**Status:** [x] complete

---

### Phase 4: Dependency and package initialization commands

**Objective:** Provide the agreed, small user interface for creating packages
and mutating URL dependencies.

**Depends on:** Phase 3

**Files to change:**

- `src/cli/mc.zig` — route and validate `mc add URL`, `mc update`, and
  `mc init --package URL`; refresh the help text.
- `src/packages/packages.zig` — expose focused mutation operations that update
  root `mc.toml` dependency arrays and regenerate `mc.lock` atomically.
- `tests/test_toolchain.py` — assert package initialization creates `src/`,
  `include/<repository-basename>/`, and a package manifest without
  `src/main.c`; assert `add` preserves existing manifest formatting as far as
  the supported TOML writer permits, deduplicates URLs, and `update` advances
  only URL dependencies.
- `src/cli/examples/mc.toml` — add concise application and dependency examples.
- `docs/build.md` — add command examples and URL/tag/commit fragment rules.
- `docs/architecture.md` — document the `packages` module, shared package
  cache, and lockfile boundary.
- `docs/TASKS.md` and `AGENTS.md` — check off/add the required one-line
  completion record once the entire feature is done, preserving the 100-line
  `AGENTS.md` limit.

**Implementation notes:**

- `mc init` with no flags stays byte-for-byte compatible in intent: it creates
  `src/main.c` and an application manifest. `mc init --package URL` derives
  `project.name` and `include/<name>/` from the URL repository basename after
  stripping a trailing slash and `.git`; it records the original URL in
  `project.repository`.
- `mc add URL` accepts a full URL only. It validates/fetches/resolves before
  editing either file, then rewrites both files through temporary siblings and
  atomic rename so failures leave the project unchanged.
- `mc update [URL...]` updates all dependencies when no URL is supplied, or
  only exact declared URLs when arguments are supplied. It never runs during
  `mc build`.
- Do not add `mc vendor`, version ranges, aliases, registry lookup, a publish
  command, or a local-path dependency option.

**Verification:**

```bash
just build
just test-toolchain
just gate
```

**Status:** [x] complete

## Testing Strategy

Add unit tests for manifest and lock parsing in `src/packages/packages.zig`,
then retain end-to-end command coverage in `tests/test_toolchain.py`. The
integration fixtures must create local bare Git remotes, so the suite has no
network dependency while exercising the identical URL/ref/cache path used for
GitHub and Forgejo.

The final suite covers backwards compatibility, application/package `main()`
rules, invalid kinds and paths, C public-header propagation, transitive ordering,
cycles, multiple dependencies, URL fragments, lock reproducibility, cache
integrity failures, `--locked`, `add`, `update`, and package scaffolding. Run
`just test-toolchain` for each phase and the full `just gate` after Phase 4.
TinyCC itself is unchanged, so `just test-legacy` is not a phase gate; it
remains part of the final `just gate` through `just test`.

## Rollout / Integration Notes

- Existing manifests require no migration: omitted `project.kind` means
  `application`, and no `dependencies` means no lockfile is required.
- Require the generated `mc.lock` to be committed for applications with URL
  dependencies. CI should invoke `mc build --locked` once command users adopt
  the feature.
- The shared cache is disposable; the lockfile is the project-owned source of
  reproducibility.
- Update docs and the task progress log only after the implementation and
  relevant gate have actually passed.

## Known Risks

- **Git availability and authentication:** Git must be on `PATH`; private
  HTTPS/SSH remotes rely on the user's normal Git credential flow. Detect a
  missing executable and report it without leaking URL credentials.
- **Mutable tags/default branches:** resolve only on `add`/`update`, pin full
  revisions plus a content hash, and make ordinary builds lock-only.
- **Cache races/corruption:** fetch into a temporary checkout and atomically
  publish it under a revision/hash key; validate lock hashes before use.
- **Transitive C linkage:** source compilation avoids binary ABI issues, but
  deterministic dependency-first source order and cycle errors are mandatory.
- **TOML preservation:** the current reader is not a formatter/writer. Limit
  automatic edits to the root dependency array and document the exact rewrite
  behavior; introduce a preserving writer only if tests show destructive edits.
- **Header-name collisions:** URLs do not solve C namespace collisions. Package
  authors own their `include/` layout and should use a distinctive prefix.

## Out of Scope

- `mc vendor` or repository-local dependency copies.
- Central registries, package search, publishing, or a GitHub/Forgejo API.
- Dependency aliases, import rewriting, or mapping a URL to a header prefix.
- Semver ranges, release channels, or dependency version solving beyond a Git
  tag/commit fragment.
- Prebuilt static/shared package artifacts and cross-target binary downloads.
- Local-path dependencies, workspaces, development overrides, and lockfile
  compatibility with Node, Go, or Zig.
- Changes to TinyCC or its legacy test suite.

## Progress Log

- 2026-08-01: Phase 0 complete. Removed the rejected uncommitted prototype;
  `just build` and the Zig unit test suite pass from the restored baseline.
- 2026-08-01: Completed URL source packages: application/package manifests,
  URL Git locks and cache, source graphs, add/update/locked builds, LSP, docs,
  local-Git integration coverage, and final gates.
