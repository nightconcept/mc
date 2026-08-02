# mc packages and applications

Status: proposed design, 2026-08-01.

## Current state

`mc build` project mode reads `[project]` and `[build]`. It resolves
`build.sources` (default `src/**/*.c`), requires exactly one top-level
`main()` unless `build.main` selects it, and links the result to a binary.
`build.include_dirs` becomes `-I`; `build.lib_dirs` and `build.libs` support
vendored pre-built libraries. `mc init` currently creates an application
with `src/main.c` and a minimal `[project]` table. See [the build
implementation](../../src/cli/mc.zig) and [Build command](../build.md).

The shared TOML reader currently exposes strings, string arrays, and
integers only, so a dependency format should initially be a string array,
not TOML inline tables. See [the parser](../../src/toml/toml.zig).

## Agreed manifest model

An application is the default project kind; it produces an executable and
must provide `main()`. A package contains reusable C sources and public
headers and must not provide an application `main()`.

```toml
# application mc.toml
[project]
name = "notes"
kind = "application" # default; may be omitted

dependencies = [
  "https://github.com/acme/mc-json",
  "https://forge.example.com/platform/mc-auth",
]
```

```toml
# package mc.toml
[project]
name = "mc-json"
version = "0.1.0"
kind = "package"
repository = "https://github.com/acme/mc-json"

[package]
sources = ["src/**/*.c"]
include_dirs = ["include"]
```

The dependency declaration is the full Git URL--there are no dependency
aliases. A package author chooses its public include layout, for example
`include/mc-json/json.h`; consumers then write:

```c
#include <mc-json/json.h>
```

`include/` is **not** analogous to Node's `node_modules/`: it is the
package's exported C-header root. The dependency cache (where `mc` fetches
package source) is the closer analogue to `node_modules`, although it should
be shared and implementation-private rather than committed or managed by
users.

`mc init --package https://github.com/acme/mc-json` should scaffold the
package manifest above plus `include/mc-json/` and `src/`, rather than
`src/main.c`. Plain `mc init` remains application scaffolding.

## Resolution and lockfile

Initial commands:

```sh
mc add https://github.com/acme/mc-json
mc add https://github.com/acme/mc-json#v1.2.0
mc add https://github.com/acme/mc-json#<commit>
mc update
mc build --locked
```

A URL without a fragment resolves its remote's declared default branch at
`mc add` or `mc update` time. The command records the resulting immutable
commit and content hash in a committed `mc.lock`; ordinary builds use that
lock rather than advancing a branch. A fragment initially denotes a Git tag
or commit. Semver ranges are deliberately deferred.

```toml
# mc.lock -- generated and committed
version = 1

[[dependency]]
url = "https://github.com/acme/mc-json"
revision = "6af04c1..." # full commit ID in real output
tree_hash = "sha256:..."
```

Each resolved package contributes its configured source files and exported
`include_dirs` to the application compile/link. This source-level build
avoids target- and ABI-specific package artifacts. Do not add `mc vendor`.

## Ecosystem precedents

- npm accepts Git remote URLs with optional `#commit-ish` and
  `#semver:<range>` fragments; a commit-ish selects a ref. Current npm
  install documentation says a full remote with no fragment uses the
  repository's default branch. It also uses a lockfile's exact resolutions
  when they satisfy manifest ranges. `mc` borrows the URL/ref ergonomics but
  deliberately keeps URLs as its only initial dependency identity.
  [npm install: Git remotes](https://docs.npmjs.com/cli/v11/commands/npm-install/#npm-install-git-remote-url),
  [npm lockfile behavior](https://docs.npmjs.com/cli/v11/commands/npm-install/#how-npm-install-uses-package-lockjson).
- Go can download module source directly from a VCS repository and clone it
  into its module cache (proxies are normally preferred for public modules).
  Its `go.sum` records cryptographic hashes; mismatches are security errors.
  This supports `mc`'s commit-and-content-hash lock design without requiring
  a central registry. [Go VCS access](https://go.dev/ref/mod#version-control-systems),
  [Go authentication and `go.sum`](https://go.dev/ref/mod#authenticating).
- Zig's build system owns package management and source dependency builds.
  It is the architectural precedent for keeping dependency acquisition and
  target-specific builds outside a global binary package format; this note
  does not rely on undocumented Zig manifest syntax. [Zig build system](https://ziglang.org/learn/build-system/),
  [Zig package-management change](https://ziglang.org/devlog/2026/#all-package-management-functionality-moved-from-compiler-to-build-system).

## Implementation order

1. Parse and validate `project.kind`, `[package]`, and string-array
   `dependencies`; implement application/package `main()` rules.
2. Support local package paths for source/include propagation and tests.
3. Add Git fetch into a shared cache, default-branch/tag/commit resolution,
   generated `mc.lock`, and `--locked` validation.
4. Add `mc add`, `mc update`, and `mc init --package`; test GitHub and a
   generic Forgejo URL with local Git remotes.
