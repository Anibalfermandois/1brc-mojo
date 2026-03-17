#!/usr/bin/env bash
# bench.sh — Standardized benchmark harness for 1BRC
#
# Usage:
#   entrypoints/bench.sh [file] [runs]
#
# Strategy:
#   1. Warm the OS page cache with one throwaway run (eliminates cold-NVMe variance).
#   2. Run N timed iterations back-to-back (default 5).
#   3. Report min / median / max wall-clock time so you can see noise, not just one number.
#   4. Run under `caffeinate -s` to prevent CPU power-gating and display sleep mid-bench.
#
# Why no `sudo purge` loop:
#   Cold-cache benchmarks are highly I/O-bound and noisy by nature (NVMe queue depth,
#   driver scheduling). Standardizing on warm-cache gives a stable, reproducible signal
#   that isolates the actual parse/compute work. If you need cold-cache numbers, run
#   `sudo purge` manually once before calling this script with RUNS=1.
#
# Tips for lower noise:
#   - Close Chrome, Slack, and other RAM-hungry apps before running.
#   - Quit Spotlight indexing: System Settings > Siri & Spotlight > disable for this volume.
#   - Plug in power (MacBook Air throttles harder on battery).
#   - Let the machine sit idle for ~30s so the thermal state settles after the warmup pass.

set -euo pipefail
cd "$(dirname "$0")/.."

FILE="${1:-measurements_300m.txt}"
RUNS="${2:-5}"

# ── Sanity checks ────────────────────────────────────────────────────────────
if [ ! -f "$FILE" ]; then
    echo "ERROR: File not found: $FILE"
    exit 1
fi

# Rebuild if binary is missing or source is newer
if [ ! -f "bin/perf_bin" ] || [ "src/perf.mojo" -nt "bin/perf_bin" ]; then
    echo "Binary out of date — rebuilding..."
    entrypoints/build.sh
fi

# ── Memory pressure check ────────────────────────────────────────────────────
# Warn if available RAM is low relative to the file being benched.
FILE_SIZE_MB=$(( $(stat -f%z "$FILE") / 1048576 ))
# vm_stat returns page counts; page size is 16384 bytes on Apple Silicon
PAGES_FREE=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
PAGES_INACTIVE=$(vm_stat | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
AVAIL_MB=$(( (PAGES_FREE + PAGES_INACTIVE) * 16384 / 1048576 ))

echo "File:            $FILE ($FILE_SIZE_MB MB)"
echo "Available RAM:   ~${AVAIL_MB} MB (free + inactive pages)"
if [ "$AVAIL_MB" -lt "$FILE_SIZE_MB" ]; then
    echo "WARNING: Available RAM ($AVAIL_MB MB) < file size ($FILE_SIZE_MB MB)."
    echo "         Warm-cache runs will be I/O bound. Consider closing other apps."
fi
echo ""

# ── Warmup pass ──────────────────────────────────────────────────────────────
echo "Warming page cache (1 throwaway run)..."
./bin/perf_bin "$FILE" 2>&1 | grep -v "Failed to initialize Crashpad" > /dev/null || true
echo "Warmup done. Starting $RUNS timed runs..."
echo ""

# ── Timed runs ───────────────────────────────────────────────────────────────
# `caffeinate -s` keeps the CPU from power-gating between iterations.
# We collect wall-clock milliseconds from bash's TIMEFORMAT.
TIMES=()

run_once() {
    local start end elapsed
    start=$(python3 -c "import time; print(int(time.time() * 1000))")
    ./bin/perf_bin "$FILE" 2>&1 | grep -v "Failed to initialize Crashpad" > /dev/null || true
    end=$(python3 -c "import time; print(int(time.time() * 1000))")
    echo $(( end - start ))
}

caffeinate -s bash -c "
    set -euo pipefail
    cd '$(pwd)'
    TIMES=()
    for i in \$(seq 1 $RUNS); do
        START=\$(python3 -c \"import time; print(int(time.time() * 1000))\")
        ./bin/perf_bin '$FILE' 2>&1 | grep -v 'Failed to initialize Crashpad' > /dev/null || true
        END=\$(python3 -c \"import time; print(int(time.time() * 1000))\")
        MS=\$(( END - START ))
        echo \"  Run \$i: \${MS}ms\"
        TIMES+=(\$MS)
    done

    # Sort times
    IFS=\$'\n' SORTED=(\$(sort -n <<<\"\${TIMES[*]}\")); unset IFS
    MIN=\${SORTED[0]}
    MAX=\${SORTED[\${#SORTED[@]}-1]}

    # Median
    MID=\$(( ($RUNS - 1) / 2 ))
    MEDIAN=\${SORTED[\$MID]}

    # Average
    SUM=0
    for t in \"\${SORTED[@]}\"; do SUM=\$(( SUM + t )); done
    AVG=\$(( SUM / $RUNS ))

    echo ''
    echo '── Results ──────────────────────────────────────────'
    printf '  min:    %dms\n'    \$MIN
    printf '  median: %dms\n'   \$MEDIAN
    printf '  avg:    %dms\n'   \$AVG
    printf '  max:    %dms\n'    \$MAX
    printf '  noise:  %dms  (+/- %d%% from median)\n' \$(( MAX - MIN )) \$(( (MAX - MIN) * 100 / (MEDIAN > 0 ? MEDIAN : 1) ))
    echo '─────────────────────────────────────────────────────'
"
