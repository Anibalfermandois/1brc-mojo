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

if [ ! -f "$BIN" ] || find src -name "*.mojo" -newer "$BIN" | grep -q .; then
    echo "🔨 Binary out of date — rebuilding..."
    entrypoints/build.sh > /dev/null
fi

echo "🔍 Running Deep Analysis on $FILE..."
echo "Note: This mode tracks collisions, distribution, and parse metrics with minimal overhead."
echo ""

ANALYZE_LOG=$(mktemp "${TMPDIR:-/tmp}/1brc-analyze.XXXXXX")
trap 'rm -f "$ANALYZE_LOG"' EXIT

if ! "$BIN" "$FILE" --analyze --once --no-print >"$ANALYZE_LOG" 2>&1; then
    awk '!/Failed to initialize Crashpad/' "$ANALYZE_LOG" >&2
    echo "ERROR: analysis run failed." >&2
    exit 1
fi

awk '!/Failed to initialize Crashpad/' "$ANALYZE_LOG"
