# justfile

default:
    just --list

build:
    python3 scripts/dev.py build

test-legacy:
    python3 scripts/dev.py test legacy

test-toolchain:
    python3 scripts/dev.py test toolchain

test:
    python3 scripts/dev.py test all

package:
    python3 scripts/dev.py package

ci:
    python3 scripts/dev.py ci

clean:
    rm -rf build dist

fmt:
    zig fmt packages/cli/mc.zig

lint file:
    ./build/mc lint {{file}}

gate:
    python3 scripts/gate.py

gate-fast:
    python3 scripts/gate.py --fast

hooks-install:
    lefthook install
