#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/helper-service-smappservice-prototype.sh ..." >&2
    exit 2
fi
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/helper-service-smappservice-prototype.sh --output-dir DIR [--case-id ID]
       scripts/helper-service-smappservice-prototype.sh --output-dir DIR --register --i-understand-this-registers-helper
       scripts/helper-service-smappservice-prototype.sh --output-dir DIR --unregister --i-understand-this-registers-helper
       scripts/helper-service-smappservice-prototype.sh --output-dir DIR --capture-post-approval
       scripts/helper-service-smappservice-prototype.sh --output-dir DIR --capture-post-reboot
       scripts/helper-service-smappservice-prototype.sh --output-dir DIR --capture-unregister --i-understand-this-registers-helper

Builds a no-membership SMAppService helper prototype evidence package for #27.
The default mode is non-mutating: it builds an ad-hoc signed app/helper bundle,
captures layout/signing/status evidence, and leaves lifecycle rows as TODO.

--register and --unregister call SMAppService and can change local helper state.
Use them only during an intentional #27 prototype run.

--capture-post-approval is non-mutating. Run it against the same existing
artifact directory after any required System Settings approval to append status,
launchctl, and log evidence.

--capture-post-reboot is non-mutating. Run it against the same existing
artifact directory after rebooting the machine to append helper bootstrap,
launchctl, and log evidence.

--capture-unregister is mutating. Run it against the same existing artifact
directory to call SMAppService unregister and append cleanup status evidence.
USAGE
}

OUTPUT_DIR=""
CASE_ID="apple-silicon-smappservice-local"
REGISTER=false
UNREGISTER=false
CAPTURE_POST_APPROVAL=false
CAPTURE_POST_REBOOT=false
CAPTURE_UNREGISTER=false
ALLOW_MUTATION=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --output-dir)
            [[ "$#" -ge 2 ]] || { echo "--output-dir requires a value" >&2; exit 64; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --case-id)
            [[ "$#" -ge 2 ]] || { echo "--case-id requires a value" >&2; exit 64; }
            CASE_ID="$2"
            shift 2
            ;;
        --register)
            REGISTER=true
            shift
            ;;
        --unregister)
            UNREGISTER=true
            shift
            ;;
        --capture-post-approval)
            CAPTURE_POST_APPROVAL=true
            shift
            ;;
        --capture-post-reboot)
            CAPTURE_POST_REBOOT=true
            shift
            ;;
        --capture-unregister)
            CAPTURE_UNREGISTER=true
            shift
            ;;
        --i-understand-this-registers-helper)
            ALLOW_MUTATION=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
    usage >&2
    exit 64
fi
MODE_COUNT=0
[[ "$REGISTER" == true ]] && MODE_COUNT=$((MODE_COUNT + 1))
[[ "$UNREGISTER" == true ]] && MODE_COUNT=$((MODE_COUNT + 1))
[[ "$CAPTURE_POST_APPROVAL" == true ]] && MODE_COUNT=$((MODE_COUNT + 1))
[[ "$CAPTURE_POST_REBOOT" == true ]] && MODE_COUNT=$((MODE_COUNT + 1))
[[ "$CAPTURE_UNREGISTER" == true ]] && MODE_COUNT=$((MODE_COUNT + 1))
if [[ "$MODE_COUNT" -gt 1 ]]; then
    echo "Use only one of --register, --unregister, --capture-post-approval, --capture-post-reboot, or --capture-unregister per run." >&2
    exit 64
fi
if [[ ( "$REGISTER" == true || "$UNREGISTER" == true || "$CAPTURE_UNREGISTER" == true ) && "$ALLOW_MUTATION" != true ]]; then
    echo "--register/--unregister/--capture-unregister require --i-understand-this-registers-helper" >&2
    exit 64
fi
APPEND_CAPTURE=false
CAPTURE_ACTION_NAME="Post-approval capture"
if [[ "$CAPTURE_POST_APPROVAL" == true || "$CAPTURE_POST_REBOOT" == true || "$CAPTURE_UNREGISTER" == true ]]; then
    APPEND_CAPTURE=true
fi
if [[ "$CAPTURE_POST_REBOOT" == true ]]; then
    CAPTURE_ACTION_NAME="Post-reboot capture"
fi
if [[ "$CAPTURE_UNREGISTER" == true ]]; then
    CAPTURE_ACTION_NAME="Unregister capture"
fi
if [[ -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ]]; then
    echo "Output path exists but is not a directory: $OUTPUT_DIR" >&2
    exit 73
fi
if [[ "$APPEND_CAPTURE" == true && ! -d "$OUTPUT_DIR" ]]; then
    echo "$CAPTURE_ACTION_NAME requires an existing artifact directory: $OUTPUT_DIR" >&2
    exit 73
fi
if [[ "$APPEND_CAPTURE" == true && -L "$OUTPUT_DIR" ]]; then
    echo "$CAPTURE_ACTION_NAME requires a real artifact directory, not a symlink: $OUTPUT_DIR" >&2
    exit 73
fi
if [[ "$APPEND_CAPTURE" == false && -e "$OUTPUT_DIR" && -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    echo "Output directory is not empty: $OUTPUT_DIR" >&2
    exit 73
fi
if [[ "$APPEND_CAPTURE" == true && -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    echo "$CAPTURE_ACTION_NAME requires a non-empty artifact directory: $OUTPUT_DIR" >&2
    exit 73
fi

DAEMON_COMMAND="${AGENTWAKE_HELPER_PROTOTYPE_DAEMON_COMMAND:-status}"
HELPER_GENERATION="${AGENTWAKE_HELPER_PROTOTYPE_GENERATION:-1}"
ROOT_LEDGER_PATH_REL="runtime/helper-ledger.jsonl"

require_positive_integer() {
    local name="$1"
    local value="$2"
    local max_value="2147483647"
    if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "$name must be a positive integer" >&2
        exit 64
    fi
    if [[ "${#value}" -gt "${#max_value}" ]] ||
        { [[ "${#value}" -eq "${#max_value}" ]] && [[ "$value" > "$max_value" ]]; }; then
        echo "$name must be a positive integer no greater than $max_value" >&2
        exit 64
    fi
}

require_helper_command() {
    local name="$1"
    local value="$2"
    if [[ "$value" == *[$'\n\r\t']* ]]; then
        echo "$name must not contain control characters" >&2
        exit 64
    fi
    case "$value" in
        status|enableBagMode|disableBagMode|repair|uninstall) ;;
        *)
            echo "$name must be one of: status, enableBagMode, disableBagMode, repair, uninstall" >&2
            exit 64
            ;;
    esac
}

if [[ "$APPEND_CAPTURE" == false ]]; then
    require_helper_command "AGENTWAKE_HELPER_PROTOTYPE_DAEMON_COMMAND" "$DAEMON_COMMAND"
    require_positive_integer "AGENTWAKE_HELPER_PROTOTYPE_GENERATION" "$HELPER_GENERATION"
fi

if [[ "$APPEND_CAPTURE" == false ]]; then
    mkdir -p "$OUTPUT_DIR"
fi
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

CONFIG_FILE="$OUTPUT_DIR/validation-config.txt"
MANIFEST_FILE="$OUTPUT_DIR/prototype-manifest.tsv"

if [[ "$APPEND_CAPTURE" == true ]]; then
    if [[ -L "$CONFIG_FILE" || ( -e "$CONFIG_FILE" && ! -f "$CONFIG_FILE" ) ]]; then
        echo "$CAPTURE_ACTION_NAME requires regular artifact file path: $CONFIG_FILE" >&2
        exit 73
    fi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "$CAPTURE_ACTION_NAME missing required artifact file path: $CONFIG_FILE" >&2
        exit 73
    fi
fi

config_value() {
    local key="$1"
    local file="${2:-$CONFIG_FILE}"
    [[ -f "$file" ]] || return 1
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

derive_identity_suffix() {
    local digest
    digest="$(printf '%s' "$OUTPUT_DIR" | shasum -a 256 | awk '{ print substr($1, 1, 10) }')"
    printf 'h%s' "$digest"
}

require_identity_suffix() {
    local name="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[A-Za-z][A-Za-z0-9]{0,31}$ ]]; then
        echo "$name must start with a letter and contain only letters/digits, max 32 chars" >&2
        exit 64
    fi
}

require_helper_label() {
    local name="$1"
    local value="$2"
    if ! [[ "$value" =~ ^com[.]makeavish[.]AgentWake[.]HelperPrototype[.][A-Za-z][A-Za-z0-9]{0,31}[.]daemon$ ]]; then
        echo "$name must be an AgentWake helper prototype label" >&2
        exit 73
    fi
}

if [[ -n "${AGENTWAKE_HELPER_PROTOTYPE_ID_SUFFIX:-}" ]]; then
    require_identity_suffix "AGENTWAKE_HELPER_PROTOTYPE_ID_SUFFIX" "$AGENTWAKE_HELPER_PROTOTYPE_ID_SUFFIX"
fi

BASE_BUNDLE_ID="com.makeavish.AgentWake.HelperPrototype"
BASE_HELPER_LABEL="com.makeavish.AgentWake.HelperPrototype"
IDENTITY_SUFFIX="${AGENTWAKE_HELPER_PROTOTYPE_ID_SUFFIX:-}"
if [[ "$APPEND_CAPTURE" == true && -f "$CONFIG_FILE" ]]; then
    HELPER_LABEL="$(config_value helperLabel "$CONFIG_FILE" || true)"
    BUNDLE_ID="$(config_value appBundleIdentifier "$CONFIG_FILE" || true)"
    IDENTITY_SUFFIX="$(config_value identitySuffix "$CONFIG_FILE" || true)"
    if [[ -z "$HELPER_LABEL" ]]; then
        echo "$CAPTURE_ACTION_NAME missing required helperLabel in validation config" >&2
        exit 73
    fi
    require_helper_label "helperLabel" "$HELPER_LABEL"
    if [[ -z "$IDENTITY_SUFFIX" ]]; then
        echo "$CAPTURE_ACTION_NAME missing required identitySuffix in validation config" >&2
        exit 73
    fi
    require_identity_suffix "identitySuffix" "$IDENTITY_SUFFIX"
    if [[ -z "$BUNDLE_ID" ]]; then
        BUNDLE_ID="$BASE_BUNDLE_ID.$IDENTITY_SUFFIX"
    fi
    if [[ "$HELPER_LABEL" != "$BASE_HELPER_LABEL.$IDENTITY_SUFFIX.daemon" ]]; then
        echo "$CAPTURE_ACTION_NAME requires helperLabel to match identitySuffix: $IDENTITY_SUFFIX" >&2
        exit 73
    fi
    if [[ "$BUNDLE_ID" != "$BASE_BUNDLE_ID.$IDENTITY_SUFFIX" ]]; then
        echo "$CAPTURE_ACTION_NAME requires appBundleIdentifier to match identitySuffix: $IDENTITY_SUFFIX" >&2
        exit 73
    fi
    DAEMON_COMMAND="$(config_value daemonCommand "$CONFIG_FILE" || true)"
    if [[ -z "$DAEMON_COMMAND" ]]; then
        echo "$CAPTURE_ACTION_NAME missing required daemonCommand in validation config" >&2
        exit 73
    fi
    require_helper_command "daemonCommand" "$DAEMON_COMMAND"
    HELPER_GENERATION="$(config_value helperGeneration "$CONFIG_FILE" || true)"
    if [[ -z "$HELPER_GENERATION" ]]; then
        HELPER_GENERATION="1"
    fi
    require_positive_integer "helperGeneration" "$HELPER_GENERATION"
    ROOT_LEDGER_PATH_REL="$(config_value rootLedgerPath "$CONFIG_FILE" || true)"
    if [[ -z "$ROOT_LEDGER_PATH_REL" ]]; then
        echo "$CAPTURE_ACTION_NAME missing required rootLedgerPath in validation config" >&2
        exit 73
    fi
    if [[ "$ROOT_LEDGER_PATH_REL" != "runtime/helper-ledger.jsonl" ]]; then
        echo "$CAPTURE_ACTION_NAME requires rootLedgerPath to be runtime/helper-ledger.jsonl" >&2
        exit 73
    fi
else
    if [[ -z "$IDENTITY_SUFFIX" ]]; then
        IDENTITY_SUFFIX="$(derive_identity_suffix)"
    fi
    require_identity_suffix "AGENTWAKE_HELPER_PROTOTYPE_ID_SUFFIX" "$IDENTITY_SUFFIX"
    BUNDLE_ID="$BASE_BUNDLE_ID.$IDENTITY_SUFFIX"
    HELPER_LABEL="$BASE_HELPER_LABEL.$IDENTITY_SUFFIX.daemon"
fi
APP_NAME="AgentWakeHelperPrototype"
HELPER_NAME="AgentWakeHelperPrototypeDaemon"
PLIST_NAME="$HELPER_LABEL.plist"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
LAUNCHD_DIR="$CONTENTS_DIR/Library/LaunchDaemons"
RUNTIME_DIR="$OUTPUT_DIR/runtime"
SOURCE_DIR="$OUTPUT_DIR/source-package"
EVIDENCE_DIR="$OUTPUT_DIR/evidence"
ROOT_LEDGER_PATH="$OUTPUT_DIR/$ROOT_LEDGER_PATH_REL"

if [[ "$APPEND_CAPTURE" == false ]]; then
    mkdir -p "$MACOS_DIR" "$LAUNCHD_DIR" "$RUNTIME_DIR" "$SOURCE_DIR" "$EVIDENCE_DIR"
fi

if [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

CODESIGN="$(xcrun --find codesign)"

capture() {
    local name="$1"
    shift
    local out="$EVIDENCE_DIR/$name.txt"
    local status_file="$EVIDENCE_DIR/$name.status"
    local start finish status
    start="$(date +%s)"
    set +e
    {
        printf '$'
        printf ' %q' "$@"
        printf '\n'
        "$@"
    } >"$out" 2>&1
    status=$?
    set -e
    finish="$(date +%s)"
    local command_parts=("$@")
    {
        printf 'command='
        printf '%q' "${command_parts[0]}"
        for part in "${command_parts[@]:1}"; do
            printf ' %q' "$part"
        done
        printf '\n'
        echo "exitCode=$status"
        echo "durationSeconds=$(( finish - start ))"
    } >"$status_file"
    return "$status"
}

capture_required() {
    local name="$1"
    if ! capture "$@"; then
        echo "Required evidence capture failed: $name" >&2
        cat "$EVIDENCE_DIR/$name.txt" >&2
        exit 1
    fi
}

capture_optional() {
    capture "$@" || true
}

capture_caller_auth_model() {
    local out="$EVIDENCE_DIR/caller-auth-model.txt"
    local status_file="$EVIDENCE_DIR/caller-auth-model.status"
    local start finish status
    start="$(date +%s)"
    set +e
    {
        printf '$ shasum -a 256 %q %q\n' "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/$HELPER_NAME"
        shasum -a 256 "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/$HELPER_NAME"
        status=$?
        if [[ "$status" -eq 0 ]]; then
            printf '$ stat -f %q %q %q %q\n' \
                'mode=%Sp owner=%Su group=%Sg path=%N' \
                "$APP_DIR" \
                "$MACOS_DIR/$APP_NAME" \
                "$MACOS_DIR/$HELPER_NAME"
            stat -f 'mode=%Sp owner=%Su group=%Sg path=%N' \
                "$APP_DIR" \
                "$MACOS_DIR/$APP_NAME" \
                "$MACOS_DIR/$HELPER_NAME"
            status=$?
        fi
    } >"$out" 2>&1
    set -e
    finish="$(date +%s)"
    {
        echo "command=caller-auth-model"
        echo "exitCode=$status"
        echo "durationSeconds=$(( finish - start ))"
    } >"$status_file"
    return "$status"
}

capture_caller_auth_model_required() {
    if ! capture_caller_auth_model; then
        echo "Required evidence capture failed: caller-auth-model" >&2
        cat "$EVIDENCE_DIR/caller-auth-model.txt" >&2
        exit 1
    fi
}

capture_fixed_command_api() {
    local out="$EVIDENCE_DIR/fixed-command-api.txt"
    local status_file="$EVIDENCE_DIR/fixed-command-api.status"
    local log_file="$RUNTIME_DIR/fixed-command-api.log"
    local ledger_file="$RUNTIME_DIR/fixed-command-api-ledger.jsonl"
    local start finish status block_status rc command rejected_command
    local allowed_commands=(status enableBagMode disableBagMode repair uninstall)
    start="$(date +%s)"
    status=0
    rejected_command="arbitraryShellCommand"
    set +e
    {
        for command in "${allowed_commands[@]}"; do
            printf '$ %q --command %q --log %q --ledger %q\n' "$MACOS_DIR/$HELPER_NAME" "$command" "$log_file" "$ledger_file"
            "$MACOS_DIR/$HELPER_NAME" --command "$command" --log "$log_file" --ledger "$ledger_file"
            rc=$?
            echo "observedExitCode[$command]=$rc"
            if [[ "$rc" -ne 0 ]]; then
                status=1
            fi
        done

        printf '$ %q --command %q --log %q --ledger %q\n' "$MACOS_DIR/$HELPER_NAME" "$rejected_command" "$log_file" "$ledger_file"
        "$MACOS_DIR/$HELPER_NAME" --command "$rejected_command" --log "$log_file" --ledger "$ledger_file"
        rc=$?
        echo "observedExitCode[$rejected_command]=$rc"
        if [[ "$rc" -eq 0 ]]; then
            status=1
        fi
    } >"$out" 2>&1
    block_status=$?
    set -e
    if [[ "$block_status" -ne 0 ]]; then
        status=1
    fi
    finish="$(date +%s)"
    {
        echo "command=fixed-command-api"
        echo "exitCode=$status"
        echo "durationSeconds=$(( finish - start ))"
    } >"$status_file"
    return "$status"
}

capture_fixed_command_api_required() {
    if ! capture_fixed_command_api; then
        echo "Required evidence capture failed: fixed-command-api" >&2
        cat "$EVIDENCE_DIR/fixed-command-api.txt" >&2
        exit 1
    fi
}

capture_expected_helper_failure() {
    local check_id="$1"
    local expected_failure="$2"
    shift 2
    local out="$EVIDENCE_DIR/$check_id.txt"
    local status_file="$EVIDENCE_DIR/$check_id.status"
    local log_file="$RUNTIME_DIR/$check_id.log"
    local start finish status rc
    start="$(date +%s)"
    status=0
    set +e
    {
        printf '$ %q --command status --log %q' "$MACOS_DIR/$HELPER_NAME" "$log_file"
        printf ' %q' "$@"
        printf '\n'
        "$MACOS_DIR/$HELPER_NAME" --command status --log "$log_file" "$@"
        rc=$?
        echo "observedExitCode=$rc"
        if [[ "$rc" -eq 0 ]]; then
            status=1
        fi
    } >"$out" 2>&1
    set -e
    if ! grep -q "$expected_failure" "$out"; then
        status=1
    fi
    finish="$(date +%s)"
    {
        echo "command=$check_id"
        echo "exitCode=$status"
        echo "durationSeconds=$(( finish - start ))"
        echo "expectedFailure=$expected_failure"
    } >"$status_file"
    return "$status"
}

capture_denied_or_revoked_approval_failure() {
    local out="$EVIDENCE_DIR/failure-denied-or-revoked-approval.txt"
    local status_file="$EVIDENCE_DIR/failure-denied-or-revoked-approval.status"
    local log_file="$RUNTIME_DIR/failure-denied-or-revoked-approval.log"
    local start finish status rc state
    start="$(date +%s)"
    status=0
    set +e
    {
        for state in denied revoked; do
            printf '$ %q --command status --log %q --approval-state %q\n' "$MACOS_DIR/$HELPER_NAME" "$log_file" "$state"
            "$MACOS_DIR/$HELPER_NAME" --command status --log "$log_file" --approval-state "$state"
            rc=$?
            echo "observedExitCode[$state]=$rc"
            if [[ "$rc" -eq 0 ]]; then
                status=1
            fi
        done
    } >"$out" 2>&1
    set -e
    if ! grep -q "approval-denied" "$out" || ! grep -q "approval-revoked" "$out"; then
        status=1
    fi
    finish="$(date +%s)"
    {
        echo "command=failure-denied-or-revoked-approval"
        echo "exitCode=$status"
        echo "durationSeconds=$(( finish - start ))"
        echo "expectedFailures=approval-denied,approval-revoked"
    } >"$status_file"
    return "$status"
}

capture_failure_cases_required() {
    capture_expected_helper_failure \
        "failure-unpaired-caller" \
        "unpaired-caller" \
        --expected-pairing-token "prototype-pairing-token" || {
            echo "Required evidence capture failed: failure-unpaired-caller" >&2
            cat "$EVIDENCE_DIR/failure-unpaired-caller.txt" >&2
            exit 1
        }

    capture_expected_helper_failure \
        "failure-wrong-bundle-id-or-label" \
        "wrong-bundle-id" \
        --expected-bundle-id "$BUNDLE_ID" \
        --actual-bundle-id "com.example.WrongBundle" \
        --expected-helper-label "$HELPER_LABEL" \
        --actual-helper-label "com.example.WrongHelper.daemon" || {
            echo "Required evidence capture failed: failure-wrong-bundle-id-or-label" >&2
            cat "$EVIDENCE_DIR/failure-wrong-bundle-id-or-label.txt" >&2
            exit 1
        }
    if ! grep -q "wrong-helper-label" "$EVIDENCE_DIR/failure-wrong-bundle-id-or-label.txt"; then
        echo "Required evidence capture failed: failure-wrong-bundle-id-or-label did not record wrong-helper-label" >&2
        cat "$EVIDENCE_DIR/failure-wrong-bundle-id-or-label.txt" >&2
        exit 1
    fi

    capture_expected_helper_failure \
        "failure-wrong-user" \
        "wrong-user" \
        --expected-effective-uid "0" \
        --actual-effective-uid "501" || {
            echo "Required evidence capture failed: failure-wrong-user" >&2
            cat "$EVIDENCE_DIR/failure-wrong-user.txt" >&2
            exit 1
        }

    capture_expected_helper_failure \
        "failure-stale-app-version" \
        "stale-app-version" \
        --expected-helper-generation "2" \
        --actual-helper-generation "1" || {
            echo "Required evidence capture failed: failure-stale-app-version" >&2
            cat "$EVIDENCE_DIR/failure-stale-app-version.txt" >&2
            exit 1
        }

    capture_denied_or_revoked_approval_failure || {
        echo "Required evidence capture failed: failure-denied-or-revoked-approval" >&2
        cat "$EVIDENCE_DIR/failure-denied-or-revoked-approval.txt" >&2
        exit 1
    }
}

config_set_key() {
    local key="$1"
    local value="$2"
    local tmp
    tmp="$(mktemp "$OUTPUT_DIR/validation-config.XXXXXX")"

    awk -F= -v key="$key" -v value="$value" '
        $1 == key {
            print key "=" value
            found = 1
            next
        }
        { print }
        END {
            if (!found) {
                print key "=" value
            }
        }
    ' "$CONFIG_FILE" >"$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

capture_file_snapshot() {
    local name="$1"
    local source_file="$2"
    local out="$EVIDENCE_DIR/$name.txt"
    local status_file="$EVIDENCE_DIR/$name.status"
    local start finish status block_status
    start="$(date +%s)"
    status=0
    set +e
    {
        printf '$ test -f %q && test -s %q && sed -n 1,200p %q\n' "$source_file" "$source_file" "$source_file"
        if [[ -L "$source_file" ]]; then
            echo "symlinkSource=$source_file"
            status=1
        elif [[ ! -e "$source_file" ]]; then
            echo "missingOrEmpty=$source_file"
            status=1
        elif [[ ! -f "$source_file" ]]; then
            echo "nonRegularSource=$source_file"
            status=1
        elif [[ -s "$source_file" ]]; then
            sed -n '1,200p' "$source_file"
            status=$?
        else
            echo "missingOrEmpty=$source_file"
            status=1
        fi
    } >"$out" 2>&1
    block_status=$?
    set -e
    if [[ "$block_status" -ne 0 ]]; then
        status=1
    fi
    finish="$(date +%s)"
    {
        echo "command=file-snapshot $source_file"
        echo "exitCode=$status"
        echo "durationSeconds=$(( finish - start ))"
    } >"$status_file"
    return "$status"
}

capture_ledger_snapshot() {
    local name="$1"
    local source_file="$2"
    local out="$EVIDENCE_DIR/$name.txt"
    local status_file="$EVIDENCE_DIR/$name.status"
    local start finish status block_status
    start="$(date +%s)"
    status=0
    set +e
    {
        printf '$ test -f %q && stat -f %q %q && sed -n 1,200p %q\n' \
            "$source_file" \
            'mode=%Sp owner=%Su group=%Sg path=%N' \
            "$source_file" \
            "$source_file"
        if [[ -L "$source_file" ]]; then
            echo "symlinkSource=$source_file"
            status=1
        elif [[ ! -e "$source_file" ]]; then
            echo "missingOrEmpty=$source_file"
            status=1
        elif [[ ! -f "$source_file" ]]; then
            echo "nonRegularSource=$source_file"
            status=1
        elif [[ -s "$source_file" ]]; then
            stat -f 'mode=%Sp owner=%Su group=%Sg path=%N' "$source_file"
            sed -n '1,200p' "$source_file"
            status=$?
        else
            echo "missingOrEmpty=$source_file"
            status=1
        fi
    } >"$out" 2>&1
    block_status=$?
    set -e
    if [[ "$block_status" -ne 0 ]]; then
        status=1
    fi
    finish="$(date +%s)"
    {
        echo "command=ledger-snapshot $source_file"
        echo "exitCode=$status"
        echo "durationSeconds=$(( finish - start ))"
    } >"$status_file"
    return "$status"
}

require_writable_capture_targets() {
    local name target
    for name in "$@"; do
        for target in "$EVIDENCE_DIR/$name.txt" "$EVIDENCE_DIR/$name.status"; do
            if [[ -L "$target" || ( -e "$target" && ! -f "$target" ) ]]; then
                echo "$CAPTURE_ACTION_NAME requires regular capture path: $target" >&2
                exit 73
            fi
            if [[ -e "$target" && ! -w "$target" ]]; then
                echo "$CAPTURE_ACTION_NAME requires writable capture path: $target" >&2
                exit 73
            fi
        done
    done
    target="$OUTPUT_DIR/post-approval-capture.md"
    if [[ "$CAPTURE_POST_REBOOT" == true ]]; then
        target="$OUTPUT_DIR/post-reboot-capture.md"
    fi
    if [[ "$CAPTURE_UNREGISTER" == true ]]; then
        target="$OUTPUT_DIR/unregister-capture.md"
    fi
    if [[ -L "$target" || ( -e "$target" && ! -f "$target" ) ]]; then
        echo "$CAPTURE_ACTION_NAME requires regular capture path: $target" >&2
        exit 73
    fi
    if [[ -e "$target" && ! -w "$target" ]]; then
        echo "$CAPTURE_ACTION_NAME requires writable capture path: $target" >&2
        exit 73
    fi
}

require_existing_capture_artifact() {
    for required_path in \
        "$APP_DIR" \
        "$CONTENTS_DIR" \
        "$MACOS_DIR" \
        "$CONTENTS_DIR/Library" \
        "$LAUNCHD_DIR"
    do
        if [[ -L "$required_path" ]]; then
            echo "$CAPTURE_ACTION_NAME requires a real artifact directory path, not a symlink: $required_path" >&2
            exit 73
        fi
        if [[ ! -d "$required_path" ]]; then
            echo "$CAPTURE_ACTION_NAME missing required artifact directory path: $required_path" >&2
            exit 73
        fi
    done
    for required_path in \
        "$CONTENTS_DIR/Info.plist" \
        "$LAUNCHD_DIR/$PLIST_NAME"
    do
        if [[ -L "$required_path" || ( -e "$required_path" && ! -f "$required_path" ) ]]; then
            echo "$CAPTURE_ACTION_NAME requires regular bundle metadata path: $required_path" >&2
            exit 73
        fi
        if [[ ! -f "$required_path" ]]; then
            echo "$CAPTURE_ACTION_NAME missing required bundle metadata path: $required_path" >&2
            exit 73
        fi
    done
    for required_path in \
        "$MACOS_DIR/$APP_NAME" \
        "$MACOS_DIR/$HELPER_NAME"
    do
        if [[ -L "$required_path" || ( -e "$required_path" && ! -f "$required_path" ) ]]; then
            echo "$CAPTURE_ACTION_NAME requires regular executable artifact path: $required_path" >&2
            exit 73
        fi
        if [[ ! -x "$required_path" ]]; then
            echo "$CAPTURE_ACTION_NAME missing required executable artifact path: $required_path" >&2
            exit 73
        fi
    done
    for required_path in \
        "$OUTPUT_DIR" \
        "$EVIDENCE_DIR" \
        "$RUNTIME_DIR"
    do
        if [[ -L "$required_path" ]]; then
            echo "$CAPTURE_ACTION_NAME requires a real artifact directory path, not a symlink: $required_path" >&2
            exit 73
        fi
        if [[ ! -d "$required_path" ]]; then
            echo "$CAPTURE_ACTION_NAME missing required artifact directory path: $required_path" >&2
            exit 73
        fi
        if [[ ! -w "$required_path" ]]; then
            echo "$CAPTURE_ACTION_NAME requires writable artifact directory path: $required_path" >&2
            exit 73
        fi
    done
    for required_path in \
        "$CONFIG_FILE" \
        "$MANIFEST_FILE"
    do
        if [[ -L "$required_path" || ( -e "$required_path" && ! -f "$required_path" ) ]]; then
            echo "$CAPTURE_ACTION_NAME requires regular artifact file path: $required_path" >&2
            exit 73
        fi
        if [[ ! -f "$required_path" ]]; then
            echo "$CAPTURE_ACTION_NAME missing required artifact file path: $required_path" >&2
            exit 73
        fi
    done
    if [[ ! -w "$CONFIG_FILE" ]]; then
        echo "$CAPTURE_ACTION_NAME requires writable validation config: $CONFIG_FILE" >&2
        exit 73
    fi
    local plist_label
    plist_label="$(plutil -extract Label raw -o - "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true)"
    if [[ "$plist_label" != "$HELPER_LABEL" ]]; then
        echo "$CAPTURE_ACTION_NAME requires LaunchDaemon Label to match helperLabel: $LAUNCHD_DIR/$PLIST_NAME" >&2
        exit 73
    fi
    local plist_executable plist_daemon_flag plist_command_flag plist_command plist_log_flag plist_log
    plist_executable="$(plutil -extract ProgramArguments.0 raw -o - "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true)"
    plist_daemon_flag="$(plutil -extract ProgramArguments.1 raw -o - "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true)"
    plist_command_flag="$(plutil -extract ProgramArguments.2 raw -o - "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true)"
    plist_command="$(plutil -extract ProgramArguments.3 raw -o - "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true)"
    plist_log_flag="$(plutil -extract ProgramArguments.4 raw -o - "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true)"
    plist_log="$(plutil -extract ProgramArguments.5 raw -o - "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true)"
    if [[ "$plist_executable" != "$MACOS_DIR/$HELPER_NAME" || "$plist_daemon_flag" != "--daemon" ]]; then
        echo "$CAPTURE_ACTION_NAME requires LaunchDaemon ProgramArguments to use the bundled helper daemon" >&2
        exit 73
    fi
    if [[ "$plist_command_flag" != "--command" || "$plist_command" != "$DAEMON_COMMAND" ]]; then
        echo "$CAPTURE_ACTION_NAME requires LaunchDaemon ProgramArguments to match daemonCommand: $DAEMON_COMMAND" >&2
        exit 73
    fi
    if [[ "$plist_log_flag" != "--log" || "$plist_log" != "$RUNTIME_DIR/helper.log" ]]; then
        echo "$CAPTURE_ACTION_NAME requires LaunchDaemon ProgramArguments to use the artifact helper log" >&2
        exit 73
    fi
    local plist_ledger_flag plist_ledger
    plist_ledger_flag="$(plutil -extract ProgramArguments.6 raw -o - "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true)"
    plist_ledger="$(plutil -extract ProgramArguments.7 raw -o - "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true)"
    if [[ "$plist_ledger_flag" != "--ledger" || "$plist_ledger" != "$ROOT_LEDGER_PATH" ]]; then
        echo "$CAPTURE_ACTION_NAME requires LaunchDaemon ProgramArguments to match rootLedgerPath: $ROOT_LEDGER_PATH_REL" >&2
        exit 73
    fi
    if plutil -extract ProgramArguments.8 raw -o - "$LAUNCHD_DIR/$PLIST_NAME" >/dev/null 2>&1; then
        echo "$CAPTURE_ACTION_NAME requires LaunchDaemon ProgramArguments to contain only the expected helper arguments" >&2
        exit 73
    fi
    local plist_stdout plist_stderr
    plist_stdout="$(plutil -extract StandardOutPath raw -o - "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true)"
    plist_stderr="$(plutil -extract StandardErrorPath raw -o - "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true)"
    if [[ "$plist_stdout" != "$RUNTIME_DIR/helper.stdout.log" ]]; then
        echo "$CAPTURE_ACTION_NAME requires LaunchDaemon StandardOutPath to use the artifact helper stdout log" >&2
        exit 73
    fi
    if [[ "$plist_stderr" != "$RUNTIME_DIR/helper.stderr.log" ]]; then
        echo "$CAPTURE_ACTION_NAME requires LaunchDaemon StandardErrorPath to use the artifact helper stderr log" >&2
        exit 73
    fi
}

assert_controller_plist_name() {
    local evidence_name="$1"
    local evidence_file="$EVIDENCE_DIR/$evidence_name.txt"
    if ! grep -Fq "plistName=$PLIST_NAME" "$evidence_file"; then
        echo "$CAPTURE_ACTION_NAME requires controller plistName to match helperLabel: $PLIST_NAME" >&2
        cat "$evidence_file" >&2
        exit 73
    fi
}

capture_post_approval_status() {
    require_existing_capture_artifact
    require_writable_capture_targets \
        helper-status-after-approval \
        launchctl-status \
        log-evidence \
        helper-bootstrap-after-approval \
        helper-stdout-after-approval \
        helper-stderr-after-approval \
        root-ledger-schema-and-permissions \
        root-ledger-ownership-sample

    capture "helper-status-after-approval" "$MACOS_DIR/$APP_NAME" status || true
    assert_controller_plist_name "helper-status-after-approval"
    capture "launchctl-status" launchctl print "system/$HELPER_LABEL" || true
    capture "log-evidence" log show --style syslog --last "${AGENTWAKE_SMAPP_LOG_LAST:-10m}" --predicate "process == \"$HELPER_NAME\" || eventMessage CONTAINS \"$HELPER_LABEL\"" || true
    capture_file_snapshot "helper-bootstrap-after-approval" "$RUNTIME_DIR/helper.log" || true
    capture_file_snapshot "helper-stdout-after-approval" "$RUNTIME_DIR/helper.stdout.log" || true
    capture_file_snapshot "helper-stderr-after-approval" "$RUNTIME_DIR/helper.stderr.log" || true
    capture_ledger_snapshot "root-ledger-schema-and-permissions" "$ROOT_LEDGER_PATH" || true
    capture_ledger_snapshot "root-ledger-ownership-sample" "$ROOT_LEDGER_PATH" || true

    config_set_key "postApprovalCaptureAttempted" "true"

    cat >"$OUTPUT_DIR/post-approval-capture.md" <<EOF
# Post-Approval Capture

This non-mutating capture appended status evidence to the existing helper
prototype artifact.

Captured files:

- \`evidence/helper-status-after-approval.txt\`
- \`evidence/launchctl-status.txt\`
- \`evidence/helper-bootstrap-after-approval.txt\`
- \`evidence/helper-stdout-after-approval.txt\`
- \`evidence/helper-stderr-after-approval.txt\`
- \`evidence/root-ledger-schema-and-permissions.txt\`
- \`evidence/root-ledger-ownership-sample.txt\`
- \`evidence/log-evidence.txt\`

This command does not promote manifest rows automatically. Review the captured
output, update the manifest and manual result deliberately, then run the
verifier before attaching the artifact to #27.
EOF

    echo "Post-approval evidence appended to $OUTPUT_DIR"
    echo "Run scripts/helper-service-prototype-verify.sh --manifest $MANIFEST_FILE to inspect remaining TODO rows."
}

capture_post_reboot_status() {
    require_existing_capture_artifact
    require_writable_capture_targets \
        helper-status-post-reboot \
        post-reboot-helper-bootstrap \
        helper-bootstrap-post-reboot \
        helper-stdout-post-reboot \
        helper-stderr-post-reboot \
        launchctl-status-post-reboot \
        log-evidence-post-reboot

    capture "helper-status-post-reboot" "$MACOS_DIR/$APP_NAME" status || true
    assert_controller_plist_name "helper-status-post-reboot"
    capture "post-reboot-helper-bootstrap" launchctl print "system/$HELPER_LABEL" || true
    capture "launchctl-status-post-reboot" launchctl print "system/$HELPER_LABEL" || true
    capture "log-evidence-post-reboot" log show --style syslog --last "${AGENTWAKE_SMAPP_LOG_LAST:-10m}" --predicate "process == \"$HELPER_NAME\" || eventMessage CONTAINS \"$HELPER_LABEL\"" || true
    capture_file_snapshot "helper-bootstrap-post-reboot" "$RUNTIME_DIR/helper.log" || true
    capture_file_snapshot "helper-stdout-post-reboot" "$RUNTIME_DIR/helper.stdout.log" || true
    capture_file_snapshot "helper-stderr-post-reboot" "$RUNTIME_DIR/helper.stderr.log" || true

    config_set_key "postRebootCaptureAttempted" "true"

    cat >"$OUTPUT_DIR/post-reboot-capture.md" <<EOF
# Post-Reboot Capture

This non-mutating capture appended reboot-lifecycle evidence to the existing
helper prototype artifact.

Captured files:

- \`evidence/helper-status-post-reboot.txt\`
- \`evidence/post-reboot-helper-bootstrap.txt\`
- \`evidence/launchctl-status-post-reboot.txt\`
- \`evidence/helper-bootstrap-post-reboot.txt\`
- \`evidence/helper-stdout-post-reboot.txt\`
- \`evidence/helper-stderr-post-reboot.txt\`
- \`evidence/log-evidence-post-reboot.txt\`

This command does not promote manifest rows automatically. Review the captured
output, update the manifest and manual result deliberately, then run the
verifier before attaching the artifact to #27.
EOF

    echo "Post-reboot evidence appended to $OUTPUT_DIR"
    echo "Run scripts/helper-service-prototype-verify.sh --manifest $MANIFEST_FILE to inspect remaining TODO rows."
}

capture_unregister_status() {
    require_existing_capture_artifact
    require_writable_capture_targets \
        helper-uninstall \
        helper-status-after-unregister \
        launchctl-status-after-unregister \
        log-evidence-after-unregister

    capture "helper-uninstall" "$MACOS_DIR/$APP_NAME" unregister || true
    assert_controller_plist_name "helper-uninstall"
    capture "helper-status-after-unregister" "$MACOS_DIR/$APP_NAME" status || true
    assert_controller_plist_name "helper-status-after-unregister"
    capture "launchctl-status-after-unregister" launchctl print "system/$HELPER_LABEL" || true
    capture "log-evidence-after-unregister" log show --style syslog --last "${AGENTWAKE_SMAPP_LOG_LAST:-10m}" --predicate "process == \"$HELPER_NAME\" || eventMessage CONTAINS \"$HELPER_LABEL\"" || true

    config_set_key "unregisterAttempted" "true"
    config_set_key "unregisterCaptureAttempted" "true"

    cat >"$OUTPUT_DIR/unregister-capture.md" <<EOF
# Unregister Capture

This mutating capture appended cleanup evidence to the existing helper
prototype artifact by calling SMAppService unregister from the same app bundle.

Captured files:

- \`evidence/helper-uninstall.txt\`
- \`evidence/helper-status-after-unregister.txt\`
- \`evidence/launchctl-status-after-unregister.txt\`
- \`evidence/log-evidence-after-unregister.txt\`

This command does not promote manifest rows automatically. Review the captured
output, update the manifest and manual result deliberately, then run the
verifier before attaching the artifact to #27.
EOF

    echo "Unregister evidence appended to $OUTPUT_DIR"
    echo "Run scripts/helper-service-prototype-verify.sh --manifest $MANIFEST_FILE to inspect remaining TODO rows."
}

xml_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    printf '%s' "$value"
}

write_controller_source() {
    mkdir -p "$SOURCE_DIR/Sources/AgentWakeHelperPrototype"
    cat >"$SOURCE_DIR/Sources/AgentWakeHelperPrototype/main.swift" <<SWIFT
import Foundation
import ServiceManagement

@main
struct Controller {
    static func main() {
        guard #available(macOS 13.0, *) else {
            print("error=SMAppService requires macOS 13 or newer")
            exit(2)
        }

        let plistName = "$PLIST_NAME"
        let service = SMAppService.daemon(plistName: plistName)
        let command = CommandLine.arguments.dropFirst().first ?? "status"

        print("command=\(command)")
        print("plistName=\(plistName)")
        print("statusBeforeRaw=\(service.status.rawValue)")
        print("statusBeforeDescription=\(String(describing: service.status))")

        do {
            switch command {
            case "status":
                break
            case "register":
                try service.register()
                print("registerResult=success")
            case "unregister":
                try service.unregister()
                print("unregisterResult=success")
            default:
                print("error=unknown command: \(command)")
                exit(64)
            }
            print("statusAfterRaw=\(service.status.rawValue)")
            print("statusAfterDescription=\(String(describing: service.status))")
        } catch {
            print("errorType=\(String(reflecting: type(of: error)))")
            print("errorDescription=\(error.localizedDescription)")
            print("error=\(String(reflecting: error))")
            print("statusAfterRaw=\(service.status.rawValue)")
            print("statusAfterDescription=\(String(describing: service.status))")
            exit(1)
        }
    }
}
SWIFT
}

write_helper_source() {
    mkdir -p "$SOURCE_DIR/Sources/AgentWakeHelperPrototypeDaemon"
    cat >"$SOURCE_DIR/Sources/AgentWakeHelperPrototypeDaemon/main.swift" <<'SWIFT'
import Foundation
import Darwin

let arguments = CommandLine.arguments
let allowedCommands: Set<String> = [
    "status",
    "enableBagMode",
    "disableBagMode",
    "repair",
    "uninstall"
]

func argumentValue(after option: String) -> String? {
    guard let index = arguments.firstIndex(of: option) else {
        return nil
    }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else {
        return nil
    }
    return arguments[valueIndex]
}

func jsonValue(_ value: String) -> String {
    guard JSONSerialization.isValidJSONObject([value]),
          let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
          let encoded = String(data: data, encoding: .utf8) else {
        return "\"<encoding-failed>\""
    }
    return String(encoded.dropFirst().dropLast())
}

func jsonArray(_ values: [String]) -> String {
    guard JSONSerialization.isValidJSONObject(values),
          let data = try? JSONSerialization.data(withJSONObject: values, options: []),
          let encoded = String(data: data, encoding: .utf8) else {
        return "[\"<encoding-failed>\"]"
    }
    return encoded
}

func normalizedAbsolutePath(_ path: String) -> String? {
    guard path.hasPrefix("/") else {
        return nil
    }
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    if standardized == "/var" {
        return "/private/var"
    }
    if standardized.hasPrefix("/var/") {
        return "/private/var/" + String(standardized.dropFirst("/var/".count))
    }
    if standardized == "/tmp" {
        return "/private/tmp"
    }
    if standardized.hasPrefix("/tmp/") {
        return "/private/tmp/" + String(standardized.dropFirst("/tmp/".count))
    }
    return standardized
}

func openVerifiedParentDirectory(for path: String) -> (fd: Int32, leaf: String)? {
    guard let normalizedPath = normalizedAbsolutePath(path) else {
        return nil
    }
    let parent = (normalizedPath as NSString).deletingLastPathComponent
    let leaf = (normalizedPath as NSString).lastPathComponent
    guard !leaf.isEmpty && leaf != "." && leaf != ".." else {
        return nil
    }

    var currentFD = open("/", O_RDONLY | O_DIRECTORY)
    if currentFD == -1 {
        return nil
    }

    for component in parent.split(separator: "/").map(String.init) {
        if component.isEmpty || component == "." {
            continue
        }
        if component == ".." {
            close(currentFD)
            return nil
        }
        let nextFD = component.withCString { name in
            openat(currentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        close(currentFD)
        if nextFD == -1 {
            return nil
        }
        currentFD = nextFD
    }

    return (currentFD, leaf)
}

func appendSafely(_ payload: String, to path: String) -> Bool {
    guard let parent = openVerifiedParentDirectory(for: path) else {
        return false
    }
    defer {
        close(parent.fd)
    }

    let fd = parent.leaf.withCString { leaf in
        openat(parent.fd, leaf, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }
    if fd == -1 {
        return false
    }
    defer {
        close(fd)
    }

    let bytes = Array(payload.utf8)
    let written = bytes.withUnsafeBufferPointer { buffer -> Int in
        guard let baseAddress = buffer.baseAddress else {
            return 0
        }
        return write(fd, baseAddress, buffer.count)
    }
    if written != bytes.count {
        return false
    }
    return fchmod(fd, S_IRUSR | S_IWUSR) == 0
}

let command = argumentValue(after: "--command") ?? "status"
let commandAllowed = allowedCommands.contains(command)
let logPath = argumentValue(after: "--log")
let ledgerPath = argumentValue(after: "--ledger")
let expectedPairingToken = argumentValue(after: "--expected-pairing-token")
let pairingToken = argumentValue(after: "--pairing-token")
let expectedBundleID = argumentValue(after: "--expected-bundle-id")
let actualBundleID = argumentValue(after: "--actual-bundle-id")
let expectedHelperLabel = argumentValue(after: "--expected-helper-label")
let actualHelperLabel = argumentValue(after: "--actual-helper-label")
let expectedEffectiveUID = argumentValue(after: "--expected-effective-uid")
let actualEffectiveUID = argumentValue(after: "--actual-effective-uid") ?? String(geteuid())
let expectedHelperGeneration = argumentValue(after: "--expected-helper-generation")
let helperGeneration = __AGENTWAKE_HELPER_GENERATION__
let actualHelperGeneration = argumentValue(after: "--actual-helper-generation") ?? String(helperGeneration)
let approvalState = argumentValue(after: "--approval-state") ?? "approved"

var authFailures: [String] = []
if let expectedPairingToken, pairingToken != expectedPairingToken {
    authFailures.append("unpaired-caller")
}
if let expectedBundleID, actualBundleID != expectedBundleID {
    authFailures.append("wrong-bundle-id")
}
if let expectedHelperLabel, actualHelperLabel != expectedHelperLabel {
    authFailures.append("wrong-helper-label")
}
if let expectedEffectiveUID, actualEffectiveUID != expectedEffectiveUID {
    authFailures.append("wrong-user")
}
if let expectedHelperGeneration, actualHelperGeneration != expectedHelperGeneration {
    authFailures.append("stale-app-version")
}
if approvalState == "denied" || approvalState == "revoked" {
    authFailures.append("approval-\(approvalState)")
}

let allowed = commandAllowed && authFailures.isEmpty
let payload = """
event=helper-command
timestampUtc=\(ISO8601DateFormatter().string(from: Date()))
pid=\(getpid())
uid=\(getuid())
euid=\(geteuid())
commandJson=\(jsonValue(command))
allowed=\(allowed)
commandAllowed=\(commandAllowed)
authFailuresJson=\(jsonArray(authFailures))
approvalState=\(jsonValue(approvalState))
helperGeneration=\(helperGeneration)
effect=dry-run
argumentsJson=\(jsonArray(arguments))

"""

let ledgerPayload = """
{"schemaVersion":1,"event":"bagModeHelperLedgerSample","timestampUtc":\(jsonValue(ISO8601DateFormatter().string(from: Date()))),"ownerTokenHash":"prototype-no-token","helperGeneration":\(helperGeneration),"bootSession":"prototype-unverified","command":\(jsonValue(command)),"allowed":\(allowed),"authFailures":\(jsonArray(authFailures)),"effect":"dry-run","priorState":{},"expectedCurrentValues":{}}

"""

if let logPath {
    if !appendSafely(payload, to: logPath) {
        fputs("logWriteError=unsafe-or-unwritable\n", stderr)
        exit(73)
    }
}

if let ledgerPath {
    if !appendSafely(ledgerPayload, to: ledgerPath) {
        fputs("ledgerWriteError=unsafe-or-unwritable\n", stderr)
        exit(73)
    }
}

print(payload, terminator: "")
if ledgerPath != nil {
    print(ledgerPayload, terminator: "")
}
if !commandAllowed {
    exit(64)
}
if !authFailures.isEmpty {
    exit(77)
}
SWIFT
    /usr/bin/sed -i '' "s/__AGENTWAKE_HELPER_GENERATION__/$HELPER_GENERATION/g" "$SOURCE_DIR/Sources/AgentWakeHelperPrototypeDaemon/main.swift"
}

write_package_manifest() {
    cat >"$SOURCE_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentWakeHelperPrototypePackage",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "AgentWakeHelperPrototype",
            targets: ["AgentWakeHelperPrototype"]
        ),
        .executable(
            name: "AgentWakeHelperPrototypeDaemon",
            targets: ["AgentWakeHelperPrototypeDaemon"]
        )
    ],
    targets: [
        .executableTarget(name: "AgentWakeHelperPrototype"),
        .executableTarget(name: "AgentWakeHelperPrototypeDaemon")
    ]
)
SWIFT
}

write_info_plist() {
    cat >"$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF
}

write_launchdaemon_plist() {
    local helper_path helper_log daemon_command root_ledger_path stdout_log stderr_log
    helper_path="$(xml_escape "$MACOS_DIR/$HELPER_NAME")"
    helper_log="$(xml_escape "$RUNTIME_DIR/helper.log")"
    daemon_command="$(xml_escape "$DAEMON_COMMAND")"
    root_ledger_path="$(xml_escape "$ROOT_LEDGER_PATH")"
    stdout_log="$(xml_escape "$RUNTIME_DIR/helper.stdout.log")"
    stderr_log="$(xml_escape "$RUNTIME_DIR/helper.stderr.log")"
    cat >"$LAUNCHD_DIR/$PLIST_NAME" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$HELPER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$helper_path</string>
    <string>--daemon</string>
    <string>--command</string>
    <string>$daemon_command</string>
    <string>--log</string>
    <string>$helper_log</string>
    <string>--ledger</string>
    <string>$root_ledger_path</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$stdout_log</string>
  <key>StandardErrorPath</key>
  <string>$stderr_log</string>
</dict>
</plist>
EOF
}

if [[ "$CAPTURE_POST_APPROVAL" == true ]]; then
    capture_post_approval_status
    exit 0
fi
if [[ "$CAPTURE_POST_REBOOT" == true ]]; then
    capture_post_reboot_status
    exit 0
fi
if [[ "$CAPTURE_UNREGISTER" == true ]]; then
    capture_unregister_status
    exit 0
fi

write_package_manifest
write_controller_source
write_helper_source
write_info_plist
write_launchdaemon_plist

swift build --package-path "$SOURCE_DIR" --product "$APP_NAME" >"$EVIDENCE_DIR/swift-build-controller.txt" 2>&1
swift build --package-path "$SOURCE_DIR" --product "$HELPER_NAME" >"$EVIDENCE_DIR/swift-build-helper.txt" 2>&1
BIN_DIR="$(swift build --package-path "$SOURCE_DIR" --show-bin-path)"
cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$BIN_DIR/$HELPER_NAME" "$MACOS_DIR/$HELPER_NAME"

capture_required "app-bundle-or-install-layout" find "$APP_DIR" -maxdepth 5 -print
capture_required "launchdaemon-plist" plutil -p "$LAUNCHD_DIR/$PLIST_NAME"
capture_optional "app-signing-or-auth-model-before-sign" "$CODESIGN" -dvvv "$APP_DIR"

"$CODESIGN" --force --sign - "$MACOS_DIR/$APP_NAME" >/dev/null 2>"$EVIDENCE_DIR/controller-codesign.stderr"
"$CODESIGN" --force --sign - "$MACOS_DIR/$HELPER_NAME" >/dev/null 2>"$EVIDENCE_DIR/helper-codesign.stderr"
"$CODESIGN" --force --sign - --deep "$APP_DIR" >/dev/null 2>"$EVIDENCE_DIR/app-bundle-codesign.stderr"

capture_required "app-signing-or-auth-model" "$CODESIGN" -dvvv "$APP_DIR"
capture_required "helper-signing-or-auth-model" "$CODESIGN" -dvvv "$MACOS_DIR/$HELPER_NAME"
capture_caller_auth_model_required
capture_fixed_command_api_required
capture_failure_cases_required
capture_optional "spctl-or-gatekeeper-assessment" spctl -a -vv "$APP_DIR"
capture_required "helper-status-before-approval" "$MACOS_DIR/$APP_NAME" status

REGISTER_EXIT=0
REGISTER_EVIDENCE_STATUS="TODO"
REGISTER_EVIDENCE_PATH=""
REGISTER_NOTE="Run --register --i-understand-this-registers-helper during the interactive #27 prototype"

if [[ "$REGISTER" == true ]]; then
    capture "helper-install-or-register" "$MACOS_DIR/$APP_NAME" register || true
    assert_controller_plist_name "helper-install-or-register"
    REGISTER_EXIT="$(sed -n 's/^exitCode=//p' "$EVIDENCE_DIR/helper-install-or-register.status" | head -n 1)"
    REGISTER_EVIDENCE_STATUS="evidence"
    REGISTER_EVIDENCE_PATH="evidence/helper-install-or-register.txt"
    REGISTER_NOTE="SMAppService register attempted; inspect status and System Settings approval state"
elif [[ "$UNREGISTER" == true ]]; then
    capture "helper-uninstall" "$MACOS_DIR/$APP_NAME" unregister || true
    assert_controller_plist_name "helper-uninstall"
fi

MACOS_VERSION="$(sw_vers -productVersion)"
HELPER_INSTALL_PATH="smappservice"
RESULT="inconclusive"
if [[ "$REGISTER" == true && "$REGISTER_EXIT" != "0" ]]; then
    RESULT="fail"
fi

cat >"$OUTPUT_DIR/validation-config.txt" <<EOF
evidenceFormat=helper-prototype-v1
metadataRedacted=true
macOSVersion=$MACOS_VERSION
appBundleIdentifier=$BUNDLE_ID
helperLabel=$HELPER_LABEL
identitySuffix=$IDENTITY_SUFFIX
launchDaemonPlist=$APP_NAME.app/Contents/Library/LaunchDaemons/$PLIST_NAME
helperInstallPath=$HELPER_INSTALL_PATH
daemonCommand=$DAEMON_COMMAND
helperGeneration=$HELPER_GENERATION
rootLedgerPath=$ROOT_LEDGER_PATH_REL
localAuthModel=ad-hoc app/helper signature plus binary hash capture; prototype helper can fail closed for pairing-token, bundle/label, effective-user, generation, and approval-state mismatches
developerIDApplicationSigned=false
packageInstallerUsed=false
homebrewCaskUsed=false
result=$RESULT
caseId=$CASE_ID
registerAttempted=$REGISTER
unregisterAttempted=$UNREGISTER
EOF

cat >"$OUTPUT_DIR/manual-result.md" <<EOF
# Helper Service Prototype Result

## Prototype Case
- Case ID: $CASE_ID
- macOS: $MACOS_VERSION
- App bundle: $APP_DIR
- LaunchDaemon plist: $APP_NAME.app/Contents/Library/LaunchDaemons/$PLIST_NAME
- Helper install path: smappservice
- Helper install API/path: SMAppService.daemon(plistName:)
- App bundle id: $BUNDLE_ID
- Helper label: $HELPER_LABEL
- Identity suffix: $IDENTITY_SUFFIX
- Daemon command: $DAEMON_COMMAND
- Helper generation: $HELPER_GENERATION
- Root ledger path: $ROOT_LEDGER_PATH_REL

## Signing
- App signed: yes
- Helper signed: yes
- Local auth model recorded: yes
- Developer ID designated requirements recorded: N/A - no Apple Developer Program membership
- Package installer used: no
- Package signed with Developer ID Installer: N/A - no package installer used

## Lifecycle
- Install/status transition: TODO - run register and capture requiresApproval/enabled state
- Admin approval/password flow confirmed: TODO - approve in System Settings if register succeeds
- Helper bootstraps after approval: TODO
- Helper bootstraps after reboot: TODO
- Old helper inactive after update: TODO
- Ledger compatibility or repair checked: TODO
- Uninstall unloaded helper: TODO
- Helper-owned Bag Mode state removed: TODO

## Failure Cases
- Failure cases recorded: yes
- Homebrew cask used: no
- Homebrew cask registers helper during install: N/A - cask not used

## Conclusion
- Result: $RESULT
EOF

manifest_row() {
    local check_id="$1"
    local status="$2"
    local path="$3"
    local note="$4"
    printf '%s\t%s\t%s\t%s\n' "$check_id" "$status" "$path" "$note"
}

{
    printf 'checkId\tstatus\tevidencePath\tnote\n'
    manifest_row "app-bundle-or-install-layout" "evidence" "evidence/app-bundle-or-install-layout.txt" "prototype app bundle built"
    manifest_row "launchdaemon-plist" "evidence" "evidence/launchdaemon-plist.txt" "bundled LaunchDaemon plist captured"
    manifest_row "app-signing-or-auth-model" "evidence" "evidence/app-signing-or-auth-model.txt" "ad-hoc app signature captured"
    manifest_row "helper-signing-or-auth-model" "evidence" "evidence/helper-signing-or-auth-model.txt" "ad-hoc helper signature captured"
    manifest_row "caller-auth-model" "evidence" "evidence/caller-auth-model.txt" "binary hashes captured; pairing token not implemented"
    manifest_row "fixed-command-api" "TODO" "" "Dry-run command parser smoke captured at evidence/fixed-command-api.txt; replace with approved helper command evidence"
    manifest_row "spctl-or-gatekeeper-assessment" "evidence" "evidence/spctl-or-gatekeeper-assessment.txt" "Gatekeeper assessment captured"
    manifest_row "helper-install-or-register" "$REGISTER_EVIDENCE_STATUS" "$REGISTER_EVIDENCE_PATH" "$REGISTER_NOTE"
    manifest_row "helper-status-after-approval" "TODO" "" "Capture after System Settings approval or fallback bootstrap"
    manifest_row "admin-approval-or-password-flow" "TODO" "" "Capture approval flow during interactive prototype"
    manifest_row "helper-bootstrap-after-approval" "TODO" "" "Capture helper runtime log after approval"
    manifest_row "post-reboot-helper-bootstrap" "TODO" "" "Capture after reboot"
    manifest_row "root-ledger-schema-and-permissions" "TODO" "" "Dry-run ledger capture is available after approval at evidence/root-ledger-schema-and-permissions.txt; promote only after root-owned helper output is reviewed"
    manifest_row "root-ledger-ownership-sample" "TODO" "" "Dry-run ledger capture is available after approval at evidence/root-ledger-ownership-sample.txt; promote only after root-owned helper output is reviewed"
    manifest_row "helper-update-old-inactive" "TODO" "" "Exercise update"
    manifest_row "helper-update-ledger-compatibility" "TODO" "" "Exercise update ledger compatibility"
    manifest_row "helper-repair-conflict" "TODO" "" "Exercise repair/conflict"
    if [[ "$UNREGISTER" == true ]]; then
        manifest_row "helper-uninstall" "evidence" "evidence/helper-uninstall.txt" "SMAppService unregister attempted"
    else
        manifest_row "helper-uninstall" "TODO" "" "Run unregister during cleanup evidence"
    fi
    manifest_row "helper-uninstall-state-cleanup" "TODO" "" "Capture cleanup"
    manifest_row "cli-helper-status-repair-uninstall" "TODO" "" "Capture CLI helper commands"
    manifest_row "failure-unpaired-caller" "evidence" "evidence/failure-unpaired-caller.txt" "Prototype helper rejected missing pairing token"
    manifest_row "failure-wrong-bundle-id-or-label" "evidence" "evidence/failure-wrong-bundle-id-or-label.txt" "Prototype helper rejected bundle id and helper label mismatches"
    manifest_row "failure-wrong-user" "evidence" "evidence/failure-wrong-user.txt" "Prototype helper rejected effective-user mismatch"
    manifest_row "failure-stale-app-version" "evidence" "evidence/failure-stale-app-version.txt" "Prototype helper rejected stale helper generation"
    manifest_row "failure-denied-or-revoked-approval" "evidence" "evidence/failure-denied-or-revoked-approval.txt" "Prototype helper rejected denied and revoked approval states"
    manifest_row "launchctl-status" "TODO" "" "Capture launchctl state after approval/bootstrap"
    manifest_row "log-evidence" "TODO" "" "Capture unified logs and helper logs"
    if [[ "$REGISTER" == true && "$REGISTER_EXIT" != "0" ]]; then
        manifest_row "smappservice-rejection" "evidence" "evidence/helper-install-or-register.txt" "register failed; inspect whether fallback is justified"
    else
        manifest_row "smappservice-rejection" "n/a" "" "SMAppService fallback not selected in this package"
    fi
    manifest_row "package-installer-signing" "n/a" "" "No package installer used"
    manifest_row "homebrew-cask-semantics" "n/a" "" "No Homebrew cask used"
} >"$OUTPUT_DIR/prototype-manifest.tsv"

OUTPUT_DIR_ARG="$(printf '%q' "$OUTPUT_DIR")"
README_INVOCATION="scripts/helper-service-smappservice-prototype.sh \\
  --output-dir $OUTPUT_DIR_ARG"
MODE_NOTICE="This artifact was produced in non-mutating prepare mode. It did not call SMAppService register or unregister."
if [[ "$REGISTER" == true ]]; then
    README_INVOCATION="$README_INVOCATION \\
  --register \\
  --i-understand-this-registers-helper"
    MODE_NOTICE="This artifact was produced in mutating register mode. It attempted SMAppService registration and may require System Settings approval or cleanup."
elif [[ "$UNREGISTER" == true ]]; then
    README_INVOCATION="$README_INVOCATION \\
  --unregister \\
  --i-understand-this-registers-helper"
    MODE_NOTICE="This artifact was produced in mutating unregister mode. It attempted SMAppService unregistration and should be treated as cleanup evidence."
fi

cat >"$OUTPUT_DIR/README.md" <<EOF
# SMAppService Helper Prototype Artifact

This artifact was produced by:

\`\`\`sh
$README_INVOCATION
\`\`\`

$MODE_NOTICE

This is not complete #27 evidence. It prepares an ad-hoc signed app/helper
bundle and records local status, signing, layout, dry-run command parser smoke,
and Gatekeeper evidence.

To attempt registration, run a new artifact with:

\`\`\`sh
scripts/helper-service-smappservice-prototype.sh \\
  --output-dir .build/helper-service-prototype/smappservice-register-\$(date -u +%Y%m%dT%H%M%SZ) \\
  --register \\
  --i-understand-this-registers-helper
\`\`\`

Registration may require System Settings approval before the helper bootstraps.
EOF

echo "SMAppService helper prototype artifact written to $OUTPUT_DIR"
echo "Verifier is expected to fail until TODO lifecycle rows are replaced with real evidence."
