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
    zig fmt src/cli/mc.zig src/fmt/format.zig src/lint/lint.zig src/lsp/lsp.zig build.zig

fmt-check:
    zig fmt --check src/cli/mc.zig src/fmt/format.zig src/lint/lint.zig src/lsp/lsp.zig build.zig

lint file:
    ./build/mc lint {{file}}

# ── meta ──────────────────────────────────────────────────────────────────────
# Update TinyCC: push changes to nightconcept/tinycc mtc branch, then run:
# just update-tinycc
update-tinycc:
    mise exec -- zig fetch --save=tinycc https://github.com/nightconcept/tinycc/archive/refs/heads/mtc.tar.gz

ci:
    just build
    just test
    just package

