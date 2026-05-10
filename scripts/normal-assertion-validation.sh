#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-"$ROOT_DIR/.build/power-validation/normal-assertions-$(date -u +%Y%m%dT%H%M%SZ)"}"
DURATION="${CLAWSHELL_ASSERTION_VALIDATION_DURATION:-10}"
READY_FILE="$OUTPUT_DIR/hold.ready"
HOLD_LOG="$OUTPUT_DIR/hold.log"

mkdir -p "$OUTPUT_DIR"

"$ROOT_DIR/scripts/pmset-snapshot.sh" "$OUTPUT_DIR/before"

swift run ClawShellPowerValidation --duration "$DURATION" --ready-file "$READY_FILE" >"$HOLD_LOG" 2>&1 &
hold_pid="$!"

cleanup() {
    if kill -0 "$hold_pid" >/dev/null 2>&1; then
        kill "$hold_pid" >/dev/null 2>&1 || true
        wait "$hold_pid" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

for _ in $(seq 1 100); do
    if [[ -f "$READY_FILE" ]]; then
        break
    fi
    sleep 0.1
done

if [[ ! -f "$READY_FILE" ]]; then
    echo "Normal assertion hold did not become ready" >&2
    cat "$HOLD_LOG" >&2 || true
    exit 1
fi

"$ROOT_DIR/scripts/pmset-snapshot.sh" "$OUTPUT_DIR/during"

wait "$hold_pid"
trap - EXIT

"$ROOT_DIR/scripts/pmset-snapshot.sh" "$OUTPUT_DIR/after"

cat >"$OUTPUT_DIR/README.txt" <<EOF
Normal assertion validation

Duration: ${DURATION}s
Phases:
- before: pmset snapshot before assertions
- during: pmset snapshot while ClawShellPowerValidation holds normal assertions
- after: pmset snapshot after assertions are released

This harness validates non-privileged IOPM assertion visibility only. It does not prove clamshell behavior.
EOF

echo "Normal assertion validation written to $OUTPUT_DIR"
