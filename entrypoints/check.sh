#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f bin/perf_bin ] || find src -name "*.mojo" -newer bin/perf_bin | grep -q .; then
    entrypoints/build.sh
fi

python3 scripts/verify_correctness.py
