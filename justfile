# justfile

default:
    just --list

# ── build ─────────────────────────────────────────────────────────────────────
build:
    python3 scripts/build.py

clean:
    rm -rf build dist .mccache .zig-cache zig-out

package:
    python3 scripts/package.py

# ── test ──────────────────────────────────────────────────────────────────────
test-legacy:
    python3 scripts/test_legacy.py

test-toolchain:
    python3 scripts/test_toolchain.py

test: test-legacy test-toolchain

# ── quality gates ─────────────────────────────────────────────────────────────
gate:
    python3 scripts/gate.py

gate-fast:
    python3 scripts/gate.py --fast

hooks-install:
    lefthook install

# ── Zig toolchain ─────────────────────────────────────────────────────────────
fetch-tools version="22":
    python3 scripts/fetch_tools.py --version {{version}}

check:
    zig build check

fmt:
    zig fmt packages/cli/mc.zig packages/fmt/format.zig packages/lint/lint.zig packages/lsp/lsp.zig build.zig

fmt-check:
    zig fmt --check packages/cli/mc.zig packages/fmt/format.zig packages/lint/lint.zig packages/lsp/lsp.zig build.zig

lint file:
    ./build/mc lint {{file}}

# ── meta ──────────────────────────────────────────────────────────────────────
ci:
    just build
    just test
    just package
