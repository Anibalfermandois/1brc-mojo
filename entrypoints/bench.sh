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
RUNS="${2:-11}"
BIN="./bin/perf_bin"
NICE_LEVEL="${BENCH_NICE:-10}"
PAUSE_SECONDS="${BENCH_PAUSE_SECONDS:-0.25}"
RUN_ID="${3:-${BENCH_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}}"
RESULT_DIR="${BENCH_RESULT_DIR:-results/benchmarks/$RUN_ID}"

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [ "$RUNS" -lt 5 ]; then
    echo "ERROR: RUNS must be an integer of at least 5."
    exit 1
fi

# ── Validation & Build ────────────────────────────────────────
if [ ! -f "$FILE" ]; then
    echo "ERROR: File not found: $FILE"
    exit 1
fi

if [ ! -f "$BIN" ] || find src -name "*.mojo" -newer "$BIN" | grep -q .; then
    echo "🔨 Binary out of date (src/*.mojo) — rebuilding..."
    entrypoints/build.sh > /dev/null
fi

mkdir -p "$RESULT_DIR"
DATASET_NAME=$(basename "$FILE" .txt)
RAW_RESULTS="$RESULT_DIR/$DATASET_NAME.csv"
SUMMARY_RESULTS="$RESULT_DIR/$DATASET_NAME.md"
METADATA="$RESULT_DIR/$DATASET_NAME.meta.txt"

# ── System Info ───────────────────────────────────────────────
FILE_SIZE_MB=$(( $(stat -f%z "$FILE") / 1048576 ))
AVAILABLE_RAM=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); free=$3} /Pages inactive/ {gsub(/\./,"",$3); inactive=$3} END { printf "~%d MB\n", (free+inactive)*16384/1048576 }')
SOURCE_FINGERPRINT=$(find src -type f -name "*.mojo" | sort | xargs shasum | shasum | awk '{print $1}')

echo "── Environment ──────────────────────────────────────"
echo "  File:           $FILE ($FILE_SIZE_MB MB)"
echo "  Available RAM:  $AVAILABLE_RAM"
echo "  Priority:       nice $NICE_LEVEL (machine remains in normal use)"
echo "  Raw results:    $RAW_RESULTS"
echo ""

{
    echo "condition=normal concurrent machine use"
    echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "dataset=$FILE"
    echo "dataset_bytes=$(stat -f%z "$FILE")"
    echo "available_ram=$AVAILABLE_RAM"
    echo "samples=$RUNS"
    echo "nice_level=$NICE_LEVEL"
    echo "pause_seconds=$PAUSE_SECONDS"
    echo "git_commit=$(git rev-parse HEAD)"
    echo "git_status_entries=$(git status --porcelain | wc -l | tr -d ' ')"
    echo "source_fingerprint=$SOURCE_FINGERPRINT"
    echo "pixi_version=$(pixi --version)"
    echo "mojo_version=$(.pixi/envs/default/bin/mojo --version)"
    echo "os=$(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "uptime_before=$(uptime)"
} > "$METADATA"

# ── Helper: get_ms ────────────────────────────────────────────
get_ms() {
    perl -MTime::HiRes=time -e 'printf "%.3f", time() * 1000'
}

RUNNER=(nice -n "$NICE_LEVEL" "$BIN")

# ── Warmup ────────────────────────────────────────────────────
echo "Warming page cache (1 throwaway run)..."
if ! WARMUP_OUTPUT=$("${RUNNER[@]}" "$FILE" --once --no-print 2>&1); then
    echo "$WARMUP_OUTPUT" >&2
    echo "ERROR: warmup failed." >&2
    exit 1
fi
if ! grep -q "Parse Time:" <<<"$WARMUP_OUTPUT"; then
    echo "$WARMUP_OUTPUT" >&2
    echo "ERROR: warmup produced no parse timing." >&2
    exit 1
fi
echo "Warmup done. Starting $RUNS timed runs..."
echo ""

# ── Benchmarking Loop ────────────────────────────────────────
echo "run,wall_ms,parse_ms" > "$RAW_RESULTS"

for i in $(seq 1 "$RUNS"); do
    T_START=$(get_ms)
    
    if ! OUT=$("${RUNNER[@]}" "$FILE" --once --no-print 2>&1); then
        echo "$OUT" >&2
        echo "ERROR: benchmark run $i failed." >&2
        exit 1
    fi
    
    T_END=$(get_ms)
    
    SHELL_MS=$(awk -v start="$T_START" -v end="$T_END" 'BEGIN { printf "%.3f", end - start }')
    MOJO_VAL=$(awk '/Parse Time:/ {print $3}' <<<"$OUT")

    if ! [[ "$MOJO_VAL" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "$OUT" >&2
        echo "ERROR: run $i produced an invalid parse timing: '$MOJO_VAL'." >&2
        exit 1
    fi
    
    printf "  Run %2d: %9.3fms wall clock  (Mojo Parse: %9.3f ms)\n" "$i" "$SHELL_MS" "$MOJO_VAL"
    printf "%d,%s,%s\n" "$i" "$SHELL_MS" "$MOJO_VAL" >> "$RAW_RESULTS"

    if [ "$i" -lt "$RUNS" ]; then
        sleep "$PAUSE_SECONDS"
    fi
done

echo ""
python3 scripts/summarize_benchmark.py "$RAW_RESULTS" | tee "$SUMMARY_RESULTS"
echo "uptime_after=$(uptime)" >> "$METADATA"
echo ""
echo "Saved metadata: $METADATA"
