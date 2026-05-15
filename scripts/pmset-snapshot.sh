#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-"$ROOT_DIR/.build/power-snapshots/$(date -u +%Y%m%dT%H%M%SZ)"}"
STRICT="${AGENTWAKE_PMSET_STRICT:-0}"
REDACT_METADATA="${AGENTWAKE_PMSET_REDACT_METADATA:-0}"

mkdir -p "$OUTPUT_DIR"

capture() {
    local required=0
    if [[ "${1:-}" == "--required" ]]; then
        required=1
        shift
    fi

    local name="$1"
    shift
    local status=0

    {
        echo "$ $*"
        "$@"
    } >"$OUTPUT_DIR/$name.txt" 2>&1 || status=$?

    if [[ "$status" -ne 0 ]]; then
        echo "command exited with status $status" >>"$OUTPUT_DIR/$name.txt"

        if [[ "$required" -eq 1 && "$STRICT" == "1" ]]; then
            echo "Required power snapshot command failed: $*" >&2
            return "$status"
        fi
    fi
}

{
    echo "capturedAtUTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$REDACT_METADATA" == "1" ]]; then
        echo "host=<redacted>"
        echo "user=<redacted>"
    else
        echo "host=$(hostname)"
        echo "user=$(id -un)"
    fi
} >"$OUTPUT_DIR/metadata.txt"

capture --required "sw_vers" sw_vers
capture --required "uname" uname -a
capture --required "pmset-assertions" pmset -g assertions
capture --required "pmset-custom" pmset -g custom
capture --required "pmset-battery" pmset -g batt
capture --required "pmset-live" pmset -g live

if command -v ioreg >/dev/null 2>&1; then
    capture "ioreg-power" ioreg -r -c IOPMPowerSource -a
fi

echo "Power snapshot written to $OUTPUT_DIR"
