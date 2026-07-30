#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

FILE="${1:-measurements_100m.txt}"
BIN="./bin/gpu_scan"

if [ ! -f "$FILE" ]; then
    echo "ERROR: File not found: $FILE" >&2
    echo "Restore it with: entrypoints/materialize-dataset.sh 100m" >&2
    exit 1
fi

mkdir -p bin
TOOLCHAINS="${GPU_METAL_TOOLCHAIN:-com.apple.dt.toolchain.Metal.32023.864}" \
pixi run mojo build \
    -O3 \
    --target-accelerator apple-m3-metal4 \
    src/gpu_scan.mojo \
    -o "$BIN"
exec nice -n "${GPU_BENCH_NICE:-10}" "$BIN" "$FILE"
