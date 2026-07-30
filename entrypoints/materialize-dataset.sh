#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DATASET="${1:-}"

case "$DATASET" in
    100m)
        OID="33da0c2a4c796f123f63ee30303132b021819222"
        EXPECTED_BYTES="1379614933"
        ;;
    300m)
        OID="88e264ab8823ec2e33cfa063fb9b7241a6ccf9f9"
        EXPECTED_BYTES="4138869766"
        ;;
    600m)
        OID="914c5cb2f0cf37a65429149e93d00b40b9d6c298"
        EXPECTED_BYTES="8277763980"
        ;;
    1b)
        OID="c15b06507befbc9c64e44af7d944b03225cc4464"
        EXPECTED_BYTES="13795859123"
        ;;
    *)
        echo "usage: materialize-dataset.sh {100m|300m|600m|1b}" >&2
        exit 2
        ;;
esac

TARGET="measurements_${DATASET}.txt"
PARTIAL="${TARGET}.partial"

if [ -f "$TARGET" ]; then
    ACTUAL_BYTES=$(stat -f%z "$TARGET")
    if [ "$ACTUAL_BYTES" = "$EXPECTED_BYTES" ]; then
        echo "$TARGET already exists with the expected size."
        exit 0
    fi
    echo "ERROR: $TARGET exists with unexpected size $ACTUAL_BYTES." >&2
    exit 1
fi

if ! git cat-file -e "$OID^{blob}"; then
    echo "ERROR: historical dataset object $OID is unavailable." >&2
    exit 1
fi

trap 'rm -f "$PARTIAL"' EXIT
echo "Materializing $TARGET from historical Git object $OID..."
nice -n "${MATERIALIZE_NICE:-10}" git cat-file blob "$OID" > "$PARTIAL"

ACTUAL_BYTES=$(stat -f%z "$PARTIAL")
if [ "$ACTUAL_BYTES" != "$EXPECTED_BYTES" ]; then
    echo "ERROR: expected $EXPECTED_BYTES bytes, got $ACTUAL_BYTES." >&2
    exit 1
fi

mv "$PARTIAL" "$TARGET"
trap - EXIT
echo "Created $TARGET ($ACTUAL_BYTES bytes)."
