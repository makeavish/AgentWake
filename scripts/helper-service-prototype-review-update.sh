#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/helper-service-prototype-review-update.sh ..." >&2
    exit 2
fi
set -euo pipefail

OLD_ARTIFACT_DIR=""
NEW_ARTIFACT_DIR=""
OUTPUT_FILE=""

usage() {
    cat <<'EOF'
Usage: scripts/helper-service-prototype-review-update.sh \
  --old-artifact DIR --new-artifact DIR [--output PATH]

Reviews two captured SMAppService helper prototype artifacts for #27 update-row
promotion candidates. The script never edits manual-result.md or
prototype-manifest.tsv.

Report columns:

checkId	recommendation	evidencePath	note
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --old-artifact)
            if [[ "$#" -lt 2 ]]; then
                echo "--old-artifact requires a value" >&2
                exit 2
            fi
            OLD_ARTIFACT_DIR="$2"
            shift 2
            ;;
        --new-artifact)
            if [[ "$#" -lt 2 ]]; then
                echo "--new-artifact requires a value" >&2
                exit 2
            fi
            NEW_ARTIFACT_DIR="$2"
            shift 2
            ;;
        --output)
            if [[ "$#" -lt 2 ]]; then
                echo "--output requires a value" >&2
                exit 2
            fi
            OUTPUT_FILE="$2"
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

if [[ -z "$OLD_ARTIFACT_DIR" || -z "$NEW_ARTIFACT_DIR" ]]; then
    echo "Provide --old-artifact and --new-artifact." >&2
    usage >&2
    exit 2
fi

if [[ ! -d "$OLD_ARTIFACT_DIR" ]]; then
    echo "Old artifact directory is not a directory: $OLD_ARTIFACT_DIR" >&2
    exit 2
fi
if [[ ! -d "$NEW_ARTIFACT_DIR" ]]; then
    echo "New artifact directory is not a directory: $NEW_ARTIFACT_DIR" >&2
    exit 2
fi

OLD_ARTIFACT_DIR="$(cd "$OLD_ARTIFACT_DIR" && pwd)"
NEW_ARTIFACT_DIR="$(cd "$NEW_ARTIFACT_DIR" && pwd)"

REPORT_TARGET="/dev/stdout"
if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    REPORT_TARGET="$OUTPUT_FILE"
fi

row() {
    local check_id="$1"
    local recommendation="$2"
    local path="$3"
    local note="$4"
    printf '%s\t%s\t%s\t%s\n' "$check_id" "$recommendation" "$path" "$note"
}

config_value() {
    local artifact_dir="$1"
    local key="$2"
    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); found = 1 } END { if (!found) exit 1 }' "$artifact_dir/validation-config.txt"
}

has_file() {
    local artifact_dir="$1"
    local name="$2"
    [[ -s "$artifact_dir/evidence/$name.txt" ]]
}

has_exit_zero() {
    local artifact_dir="$1"
    local name="$2"
    grep -q '^exitCode=0$' "$artifact_dir/evidence/$name.status" 2>/dev/null
}

has_all() {
    local artifact_dir="$1"
    local name="$2"
    shift 2
    local file="$artifact_dir/evidence/$name.txt"
    local pattern
    [[ -s "$file" ]] || return 1
    for pattern in "$@"; do
        if ! grep -Fq "$pattern" "$file"; then
            return 1
        fi
    done
}

positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

owner_token_hash() {
    local artifact_dir="$1"
    sed -n 's/.*"ownerTokenHash":"\([^"]*\)".*/\1/p' "$artifact_dir/evidence/helper-stdout-after-approval.txt" | head -n 1
}

shared_identity_ok() {
    local key
    for key in helperInstallPath identitySuffix appBundleIdentifier helperLabel; do
        if [[ "$(config_value "$OLD_ARTIFACT_DIR" "$key" 2>/dev/null || true)" != "$(config_value "$NEW_ARTIFACT_DIR" "$key" 2>/dev/null || true)" ]]; then
            return 1
        fi
    done
    [[ "$(config_value "$OLD_ARTIFACT_DIR" helperInstallPath)" == "smappservice" ]]
}

generation_values_ok() {
    local old_generation="$1"
    local new_generation="$2"
    positive_integer "$old_generation" &&
        positive_integer "$new_generation" &&
        (( new_generation > old_generation ))
}

old_enabled_ok() {
    has_exit_zero "$OLD_ARTIFACT_DIR" helper-status-after-approval &&
        has_all "$OLD_ARTIFACT_DIR" helper-status-after-approval 'statusBeforeRaw=1' 'statusAfterRaw=1' &&
        has_exit_zero "$OLD_ARTIFACT_DIR" helper-stdout-after-approval &&
        has_all "$OLD_ARTIFACT_DIR" helper-stdout-after-approval 'uid=0' 'euid=0' 'allowed=true'
}

new_enabled_ok() {
    local new_generation="$1"
    local helper_label
    helper_label="$(config_value "$NEW_ARTIFACT_DIR" helperLabel)"
    has_exit_zero "$NEW_ARTIFACT_DIR" helper-status-after-approval &&
        has_all "$NEW_ARTIFACT_DIR" helper-status-after-approval 'statusBeforeRaw=1' 'statusAfterRaw=1' &&
        has_exit_zero "$NEW_ARTIFACT_DIR" launchctl-status &&
        has_all "$NEW_ARTIFACT_DIR" launchctl-status "system/$helper_label = {" 'managed_by = com.apple.xpc.ServiceManagement' 'runs = 1' 'last exit code = 0' "$NEW_ARTIFACT_DIR/AgentWakeHelperPrototype.app/Contents/MacOS/AgentWakeHelperPrototypeDaemon" &&
        ! grep -Fq "$OLD_ARTIFACT_DIR/AgentWakeHelperPrototype.app/Contents/MacOS/AgentWakeHelperPrototypeDaemon" "$NEW_ARTIFACT_DIR/evidence/launchctl-status.txt" &&
        has_exit_zero "$NEW_ARTIFACT_DIR" helper-stdout-after-approval &&
        has_all "$NEW_ARTIFACT_DIR" helper-stdout-after-approval 'uid=0' 'euid=0' 'allowed=true' "\"helperGeneration\":$new_generation"
}

ledger_compatibility_ok() {
    local old_generation="$1"
    local new_generation="$2"
    local old_owner_token
    local new_owner_token
    old_owner_token="$(owner_token_hash "$OLD_ARTIFACT_DIR")"
    new_owner_token="$(owner_token_hash "$NEW_ARTIFACT_DIR")"

    [[ -n "$old_owner_token" && "$old_owner_token" == "$new_owner_token" ]] || return 1

    has_all "$OLD_ARTIFACT_DIR" helper-stdout-after-approval '"schemaVersion":1' '"ownerTokenHash"' "\"helperGeneration\":$old_generation" '"effect":"dry-run"' &&
        has_all "$NEW_ARTIFACT_DIR" helper-stdout-after-approval '"schemaVersion":1' '"ownerTokenHash"' "\"helperGeneration\":$new_generation" '"effect":"dry-run"'
}

old_generation="$(config_value "$OLD_ARTIFACT_DIR" helperGeneration 2>/dev/null || true)"
new_generation="$(config_value "$NEW_ARTIFACT_DIR" helperGeneration 2>/dev/null || true)"
identity_ok=false
generation_ok=false
old_ok=false
new_ok=false
ledger_ok=false

if shared_identity_ok; then
    identity_ok=true
fi
if generation_values_ok "$old_generation" "$new_generation"; then
    generation_ok=true
fi
if old_enabled_ok; then
    old_ok=true
fi
if [[ "$generation_ok" == true ]] && new_enabled_ok "$new_generation"; then
    new_ok=true
fi
if [[ "$generation_ok" == true ]] && ledger_compatibility_ok "$old_generation" "$new_generation"; then
    ledger_ok=true
fi

{
    printf 'checkId\trecommendation\tevidencePath\tnote\n'
    if [[ "$identity_ok" == true && "$generation_ok" == true && "$old_ok" == true && "$new_ok" == true && "$ledger_ok" == true ]]; then
        row helper-update-old-inactive promote-candidate "$NEW_ARTIFACT_DIR/evidence/launchctl-status.txt" "generation $new_generation helper bootstrapped for the same SMAppService label and launchctl points at the new artifact, not generation $old_generation"
    else
        row helper-update-old-inactive keep-todo "" "requires same SMAppService identity, increasing helperGeneration, old/new compatible ledger samples, old approved helper evidence, and new launchctl evidence for the expected label pointing at the new artifact only"
    fi

    if [[ "$identity_ok" == true && "$generation_ok" == true && "$old_ok" == true && "$new_ok" == true && "$ledger_ok" == true ]]; then
        row helper-update-ledger-compatibility promote-candidate "$NEW_ARTIFACT_DIR/evidence/helper-stdout-after-approval.txt" "generation $old_generation and $new_generation helpers emitted compatible schemaVersion=1 mirrored ledger samples with the same ownerTokenHash"
    else
        row helper-update-ledger-compatibility keep-todo "" "requires reviewed old/new helper stdout with schemaVersion=1, matching ownerTokenHash, and increasing helperGeneration values"
    fi
} >"$REPORT_TARGET"
