#!/usr/bin/env bash
# analyze.sh — Deep performance analysis harness for 1BRC

set -euo pipefail
cd "$(dirname "$0")/.."

# ── Self-Caffeinate ──────────────────────────────────────────
if [[ "${1:-}" != "--no-caffeinate" ]]; then
    exec caffeinate -s "$0" --no-caffeinate "$@"
fi
shift

FILE="${1:-measurements_100m.txt}"
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

echo "🔍 Running Deep Analysis on $FILE..."
echo "Note: This mode tracks collisions, distribution, and parse metrics with minimal overhead."
echo ""

# We use --once so we get the internal 'Parse Time' even in analyze mode
# (I will update perf.mojo to ensure Parse Time is printed if TRACK_METRICS is true or once is true)
"$BIN" "$FILE" --analyze --once --no-print 2>&1 | grep -v "Failed to initialize Crashpad" || true
