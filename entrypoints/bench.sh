#! /bin/bash
set -e
cd "$(dirname "$0")/.."

FILE=${1:-measurements_600m.txt}

# Check if there's no binary or if the source file was modified more recently
if [ ! -f "bin/perf_bin" ] || [ "src/perf.mojo" -nt "bin/perf_bin" ]; then
    entrypoints/build.sh
fi

echo "🚀 Running Benchmark on $FILE..."
time ./bin/perf_bin "$FILE" 2>&1 | grep -v "Failed to initialize Crashpad" || true
