#!/usr/bin/env bash
# bench.sh — Standardized benchmark harness for 1BRC

set -euo pipefail
cd "$(dirname "$0")/.."

# ── Self-Caffeinate ──────────────────────────────────────────
# Prevents system sleep during benchmark
if [[ "${1:-}" != "--no-caffeinate" ]]; then
    exec caffeinate -s "$0" --no-caffeinate "$@"
fi
shift

# ── Configuration ─────────────────────────────────────────────
FILE="${1:-measurements_300m.txt}"
RUNS="${2:-5}"
BIN="./bin/perf_bin"

# ── Validation & Build ────────────────────────────────────────
if [ ! -f "$FILE" ]; then
    echo "ERROR: File not found: $FILE"
    exit 1
fi

if [ ! -f "$BIN" ] || [ "src/perf.mojo" -nt "$BIN" ]; then
    echo "🔨 Binary out of date — rebuilding..."
    entrypoints/build.sh > /dev/null
fi

# ── System Info ───────────────────────────────────────────────
FILE_SIZE_MB=$(( $(stat -f%z "$FILE") / 1048576 ))
AVAILABLE_RAM=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); free=$3} /Pages inactive/ {gsub(/\./,"",$3); inactive=$3} END { printf "~%d MB\n", (free+inactive)*16384/1048576 }')

echo "── Environment ──────────────────────────────────────"
echo "  File:           $FILE ($FILE_SIZE_MB MB)"
echo "  Available RAM:  $AVAILABLE_RAM"
echo ""

# ── Helper: get_ms ────────────────────────────────────────────
get_ms() {
    perl -MTime::HiRes -e 'print int(Time::HiRes::gettimeofday * 1000)' 2>/dev/null || date +%s000
}

# ── Warmup ────────────────────────────────────────────────────
echo "Warming page cache (1 throwaway run)..."
"$BIN" "$FILE" --once --no-print > /dev/null 2>&1 || true
echo "Warmup done. Starting $RUNS timed runs..."
echo ""

# ── Benchmarking Loop ────────────────────────────────────────
WALL_TIMES=()
MOJO_TIMES=()

for i in $(seq 1 "$RUNS"); do
    T_START=$(get_ms)
    
    # Capture output to extract internal Mojo Parse Time
    # We use --no-print to avoid printing the 413 stations
    OUT=$("$BIN" "$FILE" --once --no-print 2>&1 || true)
    
    T_END=$(get_ms)
    
    SHELL_MS=$(( T_END - T_START ))
    MOJO_VAL=$(echo "$OUT" | awk '/Parse Time:/ {print $3}')
    
    printf "  Run %d: %4dms wall clock  (Mojo Parse: %7s ms)\n" "$i" "$SHELL_MS" "$MOJO_VAL"
    
    WALL_TIMES+=("$SHELL_MS")
    # Convert to integer for stats (removing decimal part)
    MOJO_INT=$(echo "$MOJO_VAL" | cut -d. -f1)
    MOJO_TIMES+=("${MOJO_INT:-0}")
done

# ── Statistics (based on Mojo Parse Time) ──────────────────────
IFS=$'\n' SORTED=($(sort -n <<<"${MOJO_TIMES[*]}")); unset IFS
MIN=${SORTED[0]}
MAX=${SORTED[${#SORTED[@]}-1]}
MEDIAN=${SORTED[$((RUNS / 2))]}
SUM=0; for t in "${MOJO_TIMES[@]}"; do SUM=$((SUM + t)); done
AVG=$((SUM / RUNS))

echo ""
echo "── Results (Mojo Internal Parse Time) ───────────────"
printf "  min:    %dms\n"    "$MIN"
printf "  median: %dms\n"   "$MEDIAN"
printf "  avg:    %dms\n"   "$AVG"
printf "  max:    %dms\n"    "$MAX"
printf "  noise:  %dms  (+/- %d%% from median)\n" "$(( MAX - MIN ))" "$(( (MAX - MIN) * 100 / (MEDIAN > 0 ? MEDIAN : 1) ))"
echo "──────────────────────────────────────────────────────"
echo "Note: Mojo Internal Time excludes process startup, mmap setup, and merge phases."
echo "      Wall clock includes shell overhead and binary initialization."
