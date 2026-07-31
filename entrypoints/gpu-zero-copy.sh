#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

FILE="${1:-measurements_100m.txt}"
if [ "$#" -gt 0 ]; then
    shift
fi
BRIDGE="./bin/libmetal_zero_copy.dylib"
BIN="./bin/gpu_zero_copy"

if [ ! -f "$FILE" ]; then
    echo "ERROR: File not found: $FILE" >&2
    echo "Restore it with: entrypoints/materialize-dataset.sh 100m" >&2
    exit 1
fi

mkdir -p bin
xcrun clang++ \
    -std=c++17 \
    -O3 \
    -fobjc-arc \
    -fblocks \
    -dynamiclib \
    -framework Foundation \
    -framework Metal \
    native/metal_zero_copy.mm \
    -o "$BRIDGE"

pixi run mojo build -O3 src/gpu_zero_copy.mojo -o "$BIN"

exec nice -n "${GPU_BENCH_NICE:-10}" "$BIN" "$FILE" "$BRIDGE" "$@"
