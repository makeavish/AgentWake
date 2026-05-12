#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/temperature-provider-proof-scaffold.sh ..." >&2
    exit 2
fi
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/temperature-provider-proof-scaffold.sh --output-dir DIR
   or: scripts/temperature-provider-proof-scaffold.sh DIR

Creates a non-mutating starter directory for the #25 helper-owned temperature
provider proof evidence package. The generated manifest intentionally contains
TODO rows and no validation-config.txt/manual-result.md so it cannot pass the
provider proof verifier until real helper/root sampling evidence is captured.
USAGE
}

OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            if [[ $# -lt 2 ]]; then
                echo "--output-dir requires a value" >&2
                exit 64
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
        *)
            if [[ -n "$OUTPUT_DIR" ]]; then
                echo "Output directory provided more than once" >&2
                usage >&2
                exit 64
            fi
            OUTPUT_DIR="$1"
            shift
            ;;
    esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
    usage >&2
    exit 64
fi

if [[ -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ]]; then
    echo "Output path exists but is not a directory: $OUTPUT_DIR" >&2
    exit 73
fi

if [[ -e "$OUTPUT_DIR" ]]; then
    if [[ -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
        echo "Output directory is not empty: $OUTPUT_DIR" >&2
        exit 73
    fi
fi

mkdir -p "$OUTPUT_DIR/evidence"

write_required_row() {
    local check_id="$1"
    printf '%s\tTODO\t\tReplace TODO with evidence and a captured relative evidence path before verification\n' "$check_id"
}

cat >"$OUTPUT_DIR/provider-manifest.tsv" <<'EOF'
checkId	status	evidencePath	note
EOF

{
    write_required_row "provider-command-or-api"
    write_required_row "helper-ownership-context"
    write_required_row "numeric-temperature-output"
    write_required_row "freshness-samples"
    write_required_row "active-cadence-samples"
    write_required_row "idle-cadence-samples"
    write_required_row "timeout-enforcement"
    write_required_row "timeout-fail-closed"
    write_required_row "permission-behavior"
    write_required_row "no-user-visible-prompts"
    write_required_row "closed-bag-coverage-analysis"
    write_required_row "processinfo-supplemental-signal"
    write_required_row "safety-contract-tests"
    write_required_row "unavailable-fail-closed"
    write_required_row "stale-fail-closed"
    write_required_row "permission-denied-fail-closed"
    write_required_row "parse-failed-fail-closed"
    write_required_row "helper-crashed-fail-closed"
    write_required_row "unsupported-hardware-fail-closed"
    write_required_row "logs"
    printf '%s\tn/a\t\tNo combined-sensor evidence captured yet; use evidence when closedBagCoverage=requires-combined-signals\n' "combined-sensor-signal"
    printf '%s\tn/a\t\tProvider restart or update behavior not exercised in this proof package yet\n' "provider-update-or-restart"
} >>"$OUTPUT_DIR/provider-manifest.tsv"

cat >"$OUTPUT_DIR/README.md" <<'EOF'
# Temperature Provider Proof Scaffold

This directory is a starter scaffold for issue #25. It is not evidence.

The manifest intentionally starts with `TODO` statuses for required checks and
does not create `validation-config.txt` or `manual-result.md`. Before attaching
a provider proof package to #25, replace every required row with
`status=evidence` and a relative captured evidence path, then add filled
`validation-config.txt` and `manual-result.md` files from the real helper/root
provider proof.

Run the verifier before attaching the package:

```sh
scripts/temperature-provider-proof-verify.sh --manifest <this-dir>/provider-manifest.tsv
```

Verifier success only means the evidence package is structurally complete. It
does not select a provider, run privileged sampling, or prove thermal safety.

Current local prerequisite gate:

```sh
scripts/temperature-provider-helper-readiness.sh --output-dir .build/temperature-provider-helper-readiness/local-$(date -u +%Y%m%dT%H%M%SZ)
```

The real proof still needs helper-owned numeric output, freshness within 10
seconds, 5 second active cadence, 30 second idle cadence, 1 second timeout,
prompt-free permission behavior, closed-bag coverage analysis, fail-closed
evidence, and logs.
EOF

cat >"$OUTPUT_DIR/scaffold-config.txt" <<EOF
scaffoldFormat=temperature-provider-proof-scaffold-v1
createdAtUtc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
metadataRedacted=true
manifest=provider-manifest.tsv
verifier=scripts/temperature-provider-proof-verify.sh --manifest $OUTPUT_DIR/provider-manifest.tsv
EOF

echo "Temperature provider proof scaffold written to $OUTPUT_DIR"
