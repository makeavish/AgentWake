#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/temperature-provider-fail-closed-proof.sh ..." >&2
    exit 2
fi

usage() {
    cat <<'EOF'
Usage: scripts/temperature-provider-fail-closed-proof.sh --output-dir DIR

Builds and runs the non-privileged Closed-Lid Mode safety-policy proof harness.
The generated artifact proves mocked provider failure states fail closed, but it
does not select or validate a production numeric temperature provider.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            if [[ $# -lt 2 || "${2:-}" == --* ]]; then
                echo "--output-dir requires a value" >&2
                usage >&2
                exit 2
            fi
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
    echo "--output-dir is required" >&2
    usage >&2
    exit 2
fi

case "$OUTPUT_DIR" in
    /*) ;;
    *) OUTPUT_DIR="$PWD/$OUTPUT_DIR" ;;
esac

mkdir -p "$OUTPUT_DIR"

cd "$ROOT_DIR"
swift run AgentWakeSafetyPolicyProof --output-dir "$OUTPUT_DIR"

config="$OUTPUT_DIR/validation-config.txt"
cases="$OUTPUT_DIR/fail-closed-cases.tsv"
summary="$OUTPUT_DIR/summary.md"

if [[ ! -f "$config" || ! -f "$cases" || ! -f "$summary" ]]; then
    echo "Safety policy proof did not produce the required artifact files" >&2
    exit 1
fi

if ! grep -qx 'result=pass' "$config"; then
    echo "Safety policy proof did not pass" >&2
    exit 1
fi

if ! grep -qx 'failClosedContract=covered' "$config"; then
    echo "Safety policy proof did not cover the fail-closed contract" >&2
    exit 1
fi

if ! grep -qx 'userFacingDiagnosticsCovered=true' "$config"; then
    echo "Safety policy proof did not cover user-facing diagnostics" >&2
    exit 1
fi

case_count="$(awk -F '\t' 'NR > 1 && $2 == "fail-closed" && $16 == "pass" { count++ } END { print count + 0 }' "$cases")"
if [[ "$case_count" -lt 10 ]]; then
    echo "Safety policy proof recorded too few fail-closed cases: $case_count" >&2
    exit 1
fi

diagnostic_count="$(awk -F '\t' 'NR > 1 && $2 == "fail-closed" && $13 != "" && $14 != "" && $15 != "" { count++ } END { print count + 0 }' "$cases")"
if [[ "$diagnostic_count" != "$case_count" ]]; then
    echo "Safety policy proof did not record diagnostics for every fail-closed case" >&2
    exit 1
fi

echo "Safety policy fail-closed proof verified at $OUTPUT_DIR"
