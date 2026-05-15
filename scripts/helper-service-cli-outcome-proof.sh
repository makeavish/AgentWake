#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/helper-service-cli-outcome-proof.sh ..." >&2
    exit 2
fi
set -euo pipefail

OUTPUT_DIR=""
CLI_PARSE_TEST_FILTER="cliParsesCommandsAndSendsThroughClient"
ROUTER_TEST_FILTER="controlRouterSurfacesHelperCommandOutcomes"
DEVELOPER_DIR_VALUE="${AGENTWAKE_HELPER_CLI_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

redact_metadata() {
    REDACT_HOME="${HOME:-}" REDACT_ROOT="$ROOT_DIR" perl -pe '
        BEGIN {
            $home = $ENV{"REDACT_HOME"} // "";
            $root = $ENV{"REDACT_ROOT"} // "";
        }
        s/\Q$root\E/<repo-root>/g if length($root);
        s/\Q$home\E/<home>/g if length($home);
        s#/Users/[^/\s:]+#/Users/<user>#g;
    '
}

strip_trailing_slashes() {
    local path="$1"

    while [[ "$path" != "/" && "$path" == */ ]]; do
        path="${path%/}"
    done

    printf '%s\n' "$path"
}

usage() {
    cat <<'EOF'
Usage: scripts/helper-service-cli-outcome-proof.sh --output-dir DIR

Captures #27 CLI helper command routing evidence by running the
focused ControlServer Swift test that exercises:
- agentwake helper status
- agentwake helper enable
- agentwake helper disable
- agentwake helper repair
- agentwake helper uninstall
- agentwake uninstall --remove-helper --remove-integrations cleanup flags

The harness writes validation-config.txt plus evidence/ files. It does not
install, register, approve, unregister, or contact a production helper.
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --output-dir)
            if [[ "$#" -lt 2 ]]; then
                echo "--output-dir requires a value" >&2
                exit 2
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
    echo "Provide --output-dir." >&2
    usage >&2
    exit 2
fi

OUTPUT_DIR_SYMLINK_CHECK="$(strip_trailing_slashes "$OUTPUT_DIR")"
if [[ -L "$OUTPUT_DIR_SYMLINK_CHECK" ]]; then
    echo "Output path must not be a symlink: $OUTPUT_DIR" >&2
    exit 2
fi
if [[ -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ]]; then
    echo "Output path exists and is not a directory: $OUTPUT_DIR" >&2
    exit 2
fi
if [[ -d "$OUTPUT_DIR" && -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Output directory is not empty: $OUTPUT_DIR" >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR/evidence"
OUTPUT_DIR_SYMLINK_CHECK="$(strip_trailing_slashes "$OUTPUT_DIR")"
if [[ -L "$OUTPUT_DIR_SYMLINK_CHECK" ]]; then
    echo "Output path must not be a symlink: $OUTPUT_DIR" >&2
    exit 2
fi
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
EVIDENCE_DIR="$OUTPUT_DIR/evidence"

if [[ ! -d "$DEVELOPER_DIR_VALUE" ]]; then
    echo "Full Xcode developer directory not found: $DEVELOPER_DIR_VALUE" >&2
    echo "Set AGENTWAKE_HELPER_CLI_DEVELOPER_DIR to a full Xcode developer directory." >&2
    exit 2
fi

command_status_file="$EVIDENCE_DIR/cli-helper-status-repair-uninstall.status"
command_output_file="$EVIDENCE_DIR/cli-helper-status-repair-uninstall.txt"
source_reference_file="$EVIDENCE_DIR/cli-helper-source-reference.txt"
display_developer_dir="$(printf '%s\n' "$DEVELOPER_DIR_VALUE" | redact_metadata)"

test_exit=0
start_epoch="$(date -u +%s)"
command_output_raw="$(mktemp "$EVIDENCE_DIR/.cli-helper-status-repair-uninstall.XXXXXX")"
{
    printf '$ DEVELOPER_DIR=%q swift test --filter %q\n' "$display_developer_dir" "$CLI_PARSE_TEST_FILTER"
    DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" swift test --filter "$CLI_PARSE_TEST_FILTER" || test_exit=$?
    printf '\n$ DEVELOPER_DIR=%q swift test --filter %q\n' "$display_developer_dir" "$ROUTER_TEST_FILTER"
    DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" swift test --filter "$ROUTER_TEST_FILTER" || test_exit=$?
} >"$command_output_raw" 2>&1
redact_metadata <"$command_output_raw" >"$command_output_file"
rm -f "$command_output_raw"
end_epoch="$(date -u +%s)"
duration_seconds=$((end_epoch - start_epoch))

{
    printf 'commands=DEVELOPER_DIR=%s swift test --filter %s; DEVELOPER_DIR=%s swift test --filter %s\n' \
        "$display_developer_dir" \
        "$CLI_PARSE_TEST_FILTER" \
        "$display_developer_dir" \
        "$ROUTER_TEST_FILTER"
    printf 'exitCode=%s\n' "$test_exit"
    printf 'durationSeconds=%s\n' "$duration_seconds"
    printf 'developerDir=%s\n' "$display_developer_dir"
    printf 'cliParseTestFilter=%s\n' "$CLI_PARSE_TEST_FILTER"
    printf 'routerTestFilter=%s\n' "$ROUTER_TEST_FILTER"
} >"$command_status_file"

source_reference_raw="$(mktemp "$EVIDENCE_DIR/.cli-helper-source-reference.XXXXXX")"
{
    printf '$ rg -n %q Tests/AgentWakeCoreTests/ControlServerTests.swift Sources/AgentWakeCore\n' "$CLI_PARSE_TEST_FILTER|$ROUTER_TEST_FILTER"
    rg -n "$CLI_PARSE_TEST_FILTER|$ROUTER_TEST_FILTER|helper status|helper enable|helper disable|helper repair|helper uninstall|remove-helper|removeIntegrations|uninstall\\(" \
        Tests/AgentWakeCoreTests/ControlServerTests.swift \
        Sources/AgentWakeCore || true
} >"$source_reference_raw" 2>&1
redact_metadata <"$source_reference_raw" >"$source_reference_file"
rm -f "$source_reference_raw"

proof_ready=false
test_passed=false
if [[ "$test_exit" == "0" ]] &&
   grep -Fq 'Test cliParsesCommandsAndSendsThroughClient() passed' "$command_output_file" &&
   grep -Fq 'Test controlRouterSurfacesHelperCommandOutcomes() passed' "$command_output_file" &&
   grep -Eq 'Test run with 1 test in 1 suite passed|Test run with 1 test .* passed' "$command_output_file"; then
    test_passed=true
    proof_ready=true
fi

cat >"$OUTPUT_DIR/validation-config.txt" <<EOF
evidenceFormat=helper-cli-outcome-proof-v1
metadataRedacted=true
developerDir=$display_developer_dir
cliParseTestFilter=$CLI_PARSE_TEST_FILTER
routerTestFilter=$ROUTER_TEST_FILTER
testPassed=$test_passed
cliHelperStatusEnableDisableRepairUninstallCovered=$test_passed
cliHelperStatusRepairUninstallCovered=$test_passed
helperCliOutcomeProofReady=$proof_ready
result=$([[ "$proof_ready" == true ]] && printf 'pass' || printf 'fail')
EOF

cat >"$OUTPUT_DIR/README.md" <<EOF
# Helper CLI Outcome Proof

This package captures focused CLI routing evidence for #27.

It runs:

\`\`\`sh
DEVELOPER_DIR=$display_developer_dir swift test --filter $CLI_PARSE_TEST_FILTER
DEVELOPER_DIR=$display_developer_dir swift test --filter $ROUTER_TEST_FILTER
\`\`\`

Evidence files:

- \`evidence/cli-helper-status-repair-uninstall.txt\`
- \`evidence/cli-helper-status-repair-uninstall.status\`
- \`evidence/cli-helper-source-reference.txt\`

Boundary: this proves CLI parse/routing and ControlServer outcome messages for
helper status, enable, disable, repair, uninstall, and top-level cleanup flags.
It does not prove a production helper is installed, repaired, uninstalled, or
cleaned up.
EOF

echo "Helper CLI outcome proof written to $OUTPUT_DIR"
if [[ "$proof_ready" != true ]]; then
    echo "Proof is not ready; inspect $command_output_file" >&2
    exit 1
fi
