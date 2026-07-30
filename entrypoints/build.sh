#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p bin
echo "🔨 Building perf.mojo with Ahead-Of-Time (AOT) -O3 optimizations..."

BUILD_LOG=$(mktemp "${TMPDIR:-/tmp}/1brc-build.XXXXXX")
trap 'rm -f "$BUILD_LOG"' EXIT

if ! (cd src && pixi run mojo build -O3 perf.mojo -o ../bin/perf_bin) >"$BUILD_LOG" 2>&1; then
    awk '!/Failed to initialize Crashpad/' "$BUILD_LOG" >&2
    echo "ERROR: build failed; no benchmark will use a stale binary." >&2
    exit 1
fi

awk '!/Failed to initialize Crashpad/' "$BUILD_LOG"

echo "✅ Build complete: ./bin/perf_bin"
