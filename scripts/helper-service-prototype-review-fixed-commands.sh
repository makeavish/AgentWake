#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/helper-service-prototype-review-fixed-commands.sh ..." >&2
    exit 2
fi
set -euo pipefail

OUTPUT_FILE=""
COMMAND_ARTIFACTS=()
REQUIRED_COMMANDS=(status enableBagMode disableBagMode repair uninstall)

usage() {
    cat <<'EOF'
Usage: scripts/helper-service-prototype-review-fixed-commands.sh --command-artifact COMMAND=DIR [...] [--output PATH]

Reviews approved SMAppService helper prototype command artifacts for #27. The
script emits a TSV report for the fixed-command API row without editing any
evidence package.

Expected commands:
status, enableBagMode, disableBagMode, repair, uninstall

Report columns:
command	recommendation	artifactDir	evidencePath	note
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --command-artifact)
            if [[ "$#" -lt 2 ]]; then
                echo "--command-artifact requires COMMAND=DIR" >&2
                exit 2
            fi
            COMMAND_ARTIFACTS+=("$2")
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

if [[ "${#COMMAND_ARTIFACTS[@]}" -eq 0 ]]; then
    echo "Provide at least one --command-artifact COMMAND=DIR mapping." >&2
    usage >&2
    exit 2
fi

REPORT_TARGET="/dev/stdout"
if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    REPORT_TARGET="$OUTPUT_FILE"
fi

is_required_command() {
    local command="$1"
    local required
    for required in "${REQUIRED_COMMANDS[@]}"; do
        [[ "$command" == "$required" ]] && return 0
    done
    return 1
}

trim_path() {
    local path="$1"
    printf '%s' "$path" | sed 's#//*#/#g; s#/$##'
}

artifact_for_command() {
    local command="$1"
    local mapping key value
    for mapping in "${COMMAND_ARTIFACTS[@]}"; do
        key="${mapping%%=*}"
        value="${mapping#*=}"
        if [[ "$mapping" != *=* || -z "$key" || -z "$value" ]]; then
            continue
        fi
        if [[ "$key" == "$command" ]]; then
            printf '%s' "$value"
            return 0
        fi
    done
    return 1
}

value_for_key() {
    local key="$1"
    local file="$2"
    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); found = 1 } END { if (!found) exit 1 }' "$file"
}

has_file() {
    local file="$1"
    [[ -s "$file" ]]
}

has_all() {
    local file="$1"
    shift
    [[ -s "$file" ]] || return 1
    local pattern
    for pattern in "$@"; do
        if ! grep -Fq "$pattern" "$file"; then
            return 1
        fi
    done
    return 0
}

has_any() {
    local file="$1"
    shift
    [[ -s "$file" ]] || return 1
    local pattern
    for pattern in "$@"; do
        if grep -Fq "$pattern" "$file"; then
            return 0
        fi
    done
    return 1
}

row() {
    local command="$1"
    local recommendation="$2"
    local artifact_dir="$3"
    local evidence_path="$4"
    local note="$5"
    printf '%s\t%s\t%s\t%s\t%s\n' "$command" "$recommendation" "$artifact_dir" "$evidence_path" "$note"
}

review_command() {
    local command="$1"
    local artifact_dir raw_artifact_dir
    raw_artifact_dir="$(artifact_for_command "$command" || true)"
    if [[ -z "$raw_artifact_dir" ]]; then
        row "$command" keep-todo "" "" "missing command artifact mapping"
        return 1
    fi
    artifact_dir="$(trim_path "$raw_artifact_dir")"
    if [[ ! -d "$artifact_dir" ]]; then
        row "$command" keep-todo "$artifact_dir" "" "mapped artifact is not a directory"
        return 1
    fi

    local config stdout stdout_status helper_status helper_status_status launchctl launchctl_status uninstall uninstall_status launchctl_after config_command
    config="$artifact_dir/validation-config.txt"
    stdout="$artifact_dir/evidence/helper-stdout-after-approval.txt"
    stdout_status="$artifact_dir/evidence/helper-stdout-after-approval.status"
    helper_status="$artifact_dir/evidence/helper-status-after-approval.txt"
    helper_status_status="$artifact_dir/evidence/helper-status-after-approval.status"
    launchctl="$artifact_dir/evidence/launchctl-status.txt"
    launchctl_status="$artifact_dir/evidence/launchctl-status.status"
    uninstall="$artifact_dir/evidence/helper-uninstall.txt"
    uninstall_status="$artifact_dir/evidence/helper-uninstall.status"
    launchctl_after="$artifact_dir/evidence/launchctl-status-after-unregister.txt"

    if ! has_file "$config"; then
        row "$command" keep-todo "$artifact_dir" "" "missing validation-config.txt"
        return 1
    fi
    config_command="$(value_for_key daemonCommand "$config" 2>/dev/null || true)"
    if [[ "$config_command" != "$command" ]]; then
        row "$command" keep-todo "$artifact_dir" "validation-config.txt" "daemonCommand is '$config_command', expected '$command'"
        return 1
    fi
    if ! grep -q '^postApprovalCaptureAttempted=true$' "$config"; then
        row "$command" keep-todo "$artifact_dir" "validation-config.txt" "post-approval capture was not recorded"
        return 1
    fi
    if ! grep -q '^unregisterCaptureAttempted=true$' "$config"; then
        row "$command" keep-todo "$artifact_dir" "validation-config.txt" "cleanup unregister capture was not recorded"
        return 1
    fi
    if ! has_all "$helper_status_status" 'exitCode=0' ||
       ! has_all "$helper_status" 'statusBeforeRaw=1' 'statusAfterRaw=1'; then
        row "$command" keep-todo "$artifact_dir" "evidence/helper-status-after-approval.txt" "enabled status evidence is incomplete"
        return 1
    fi
    if ! has_all "$launchctl_status" 'exitCode=0' ||
       ! has_all "$launchctl" 'managed_by = com.apple.xpc.ServiceManagement' 'runs = 1' 'last exit code = 0'; then
        row "$command" keep-todo "$artifact_dir" "evidence/launchctl-status.txt" "launchd ServiceManagement evidence is incomplete"
        return 1
    fi
    if ! has_all "$stdout_status" 'exitCode=0'; then
        row "$command" keep-todo "$artifact_dir" "evidence/helper-stdout-after-approval.status" "helper stdout capture did not complete successfully"
        return 1
    fi
    if ! has_all "$stdout" \
        'uid=0' \
        'euid=0' \
        "commandJson=\"$command\"" \
        'allowed=true' \
        'effect=dry-run' \
        '"event":"bagModeHelperLedgerSample"' \
        "\"command\":\"$command\"" \
        '"allowed":true' \
        '"effect":"dry-run"'; then
        row "$command" keep-todo "$artifact_dir" "evidence/helper-stdout-after-approval.txt" "root dry-run command stdout or mirrored ledger sample is incomplete"
        return 1
    fi
    if ! has_all "$uninstall_status" 'exitCode=0' ||
       ! has_all "$uninstall" \
        'unregisterResult=success' \
        'statusBeforeRaw=1' \
        'statusAfterRaw=0'; then
        row "$command" keep-todo "$artifact_dir" "evidence/helper-uninstall.txt" "cleanup unregister evidence is incomplete"
        return 1
    fi
    if ! has_any "$launchctl_after" 'Could not find service' 'service not found' 'Could not find specified service'; then
        row "$command" keep-todo "$artifact_dir" "evidence/launchctl-status-after-unregister.txt" "launchctl service-not-found cleanup evidence is missing"
        return 1
    fi

    row "$command" promote-candidate "$artifact_dir" "evidence/helper-stdout-after-approval.txt" "approved helper dispatched fixed command as root and cleaned up"
    return 0
}

{
    printf 'command\trecommendation\tartifactDir\tevidencePath\tnote\n'
    all_pass=true
    for command in "${REQUIRED_COMMANDS[@]}"; do
        if ! review_command "$command"; then
            all_pass=false
        fi
    done
    if [[ "$all_pass" == true ]]; then
        row fixed-command-api promote-candidate "" "" "all fixed commands have approved root dry-run dispatch and cleanup evidence"
    else
        row fixed-command-api keep-todo "" "" "one or more fixed-command artifacts are missing or incomplete"
    fi

    mapping_command=""
    for mapping in "${COMMAND_ARTIFACTS[@]}"; do
        mapping_command="${mapping%%=*}"
        if [[ "$mapping" != *=* || -z "$mapping_command" || "$mapping_command" == "$mapping" ]]; then
            row unknown keep-todo "" "" "invalid command artifact mapping: $mapping"
        elif ! is_required_command "$mapping_command"; then
            row "$mapping_command" keep-todo "${mapping#*=}" "" "unknown fixed command mapping"
        fi
    done
} >"$REPORT_TARGET"
