#! /bin/bash
set -e
cd "$(dirname "$0")/.."

mkdir -p bin
echo "🔨 Building perf.mojo with Ahead-Of-Time (AOT) -O3 optimizations..."
# Build with AOT optimizations and suppress Crashpad warning
(cd src && mojo build -O3 perf.mojo -o ../bin/perf_bin) 2>&1 | grep -v "Failed to initialize Crashpad" || true

echo "✅ Build complete: ./bin/perf_bin"
