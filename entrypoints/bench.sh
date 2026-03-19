#!/usr/bin/env bash
# bench.sh — Standardized benchmark harness for 1BRC

set -euo pipefail
cd "$(dirname "$0")/.."

FILE="${1:-measurements_300m.txt}"
RUNS="${2:-5}"

if [ ! -f "$FILE" ]; then
    echo "ERROR: File not found: $FILE"
    exit 1
fi

if [ ! -f "bin/perf_bin" ] || [ "src/perf.mojo" -nt "bin/perf_bin" ]; then
    echo "Binary out of date — rebuilding..."
    entrypoints/build.sh
fi

FILE_SIZE_MB=$(( $(stat -f%z "$FILE") / 1048576 ))
PAGES_FREE=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
PAGES_INACTIVE=$(vm_stat | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
AVAIL_MB=$(( (PAGES_FREE + PAGES_INACTIVE) * 16384 / 1048576 ))

echo "File:            $FILE ($FILE_SIZE_MB MB)"
echo "Available RAM:   ~${AVAIL_MB} MB (free + inactive pages)"
echo ""

echo "Warming page cache (1 throwaway run)..."
./bin/perf_bin "$FILE" --once 2>&1 | grep -v "Failed to initialize Crashpad" > /dev/null || true
echo "Warmup done. Starting $RUNS timed runs..."
echo ""

caffeinate -s bash -c "
    set -euo pipefail
    cd '$(pwd)'
    TIMES=()
    for i in \$(seq 1 $RUNS); do
        START=\$(python3 -c 'import time; print(int(time.time() * 1000))')
        ./bin/perf_bin '$FILE' --once 2>&1 | grep -v 'Failed to initialize Crashpad' > /dev/null || true
        END=\$(python3 -c 'import time; print(int(time.time() * 1000))')
        MS=\$(( END - START ))
        echo \"  Run \$i: \${MS}ms\"
        TIMES+=(\$MS)
    done

    IFS=\$'\n' SORTED=(\$(sort -n <<<\"\${TIMES[*]}\")); unset IFS
    MIN=\${SORTED[0]}
    MAX=\${SORTED[\${#SORTED[@]}-1]}
    MID=\$(( ($RUNS - 1) / 2 ))
    MEDIAN=\${SORTED[\$MID]}
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
