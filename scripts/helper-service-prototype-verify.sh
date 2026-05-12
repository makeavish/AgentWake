#!/usr/bin/env bash
set -euo pipefail

MANIFEST_FILE=""
SEEN_CHECK_IDS=("__sentinel__")
case_errors=0
PACKAGE_INSTALLER_USED=""
HOMEBREW_CASK_USED=""
PACKAGE_INSTALLER_STATUS=""
HOMEBREW_CASK_STATUS=""
CONFIG_MACOS_VERSION=""
CONFIG_LAUNCHDAEMON_PLIST=""
CONFIG_RESULT=""

usage() {
    cat <<'EOF'
Usage: scripts/helper-service-prototype-verify.sh --manifest PATH

Checks the signed SMAppService helper prototype evidence package for #27. This
verifier is structural only: it fails missing, placeholder, or internally
inconsistent evidence before the package is attached to the issue. It does not
sign, install, register, approve, unregister, or run a helper.

The manifest must be a TSV file with this header:

checkId	status	evidencePath	note

Required check rows must use status "evidence" and a relative evidence path.
Optional package/cask rows may use "n/a" with an explicit note when not used.
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --manifest)
            if [[ "$#" -lt 2 ]]; then
                echo "--manifest requires a value" >&2
                exit 2
            fi
            MANIFEST_FILE="$2"
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

if [[ -z "$MANIFEST_FILE" ]]; then
    echo "Provide --manifest." >&2
    usage >&2
    exit 2
fi

if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "Manifest is not a file: $MANIFEST_FILE" >&2
    exit 2
fi

MANIFEST_DIR="$(cd "$(dirname "$MANIFEST_FILE")" && pwd)"
CONFIG_FILE="$MANIFEST_DIR/validation-config.txt"
MANUAL_FILE="$MANIFEST_DIR/manual-result.md"

required_check_ids() {
    cat <<'EOF'
app-bundle-layout
launchdaemon-plist
app-codesign
helper-codesign
app-designated-requirement
helper-designated-requirement
spctl-assessment
smappservice-register
smappservice-status-requires-approval
system-settings-approval
smappservice-status-enabled
helper-bootstrap-after-approval
post-reboot-helper-bootstrap
helper-update-old-inactive
helper-update-ledger-compatibility
helper-uninstall-unregister
helper-uninstall-state-cleanup
failure-unsigned-caller
failure-wrong-bundle-id-or-label
failure-wrong-user
failure-stale-app-version
failure-denied-or-revoked-approval
launchctl-status
log-evidence
EOF
}

optional_check_ids() {
    cat <<'EOF'
package-installer-signing
homebrew-cask-semantics
EOF
}

trim_value() {
    printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

record_error() {
    local context="$1"
    local message="$2"
    printf 'ERROR [%s] %s\n' "$context" "$message" >&2
    case_errors=$((case_errors + 1))
}

is_unfilled_value() {
    local value
    value="$(trim_value "$1")"

    [[ -z "$value" ]] && return 0
    [[ "$value" == "TODO" ]] && return 0
    [[ "$value" == "TBD" ]] && return 0
    [[ "$value" == *"<"* && "$value" == *">"* ]] && return 0
    [[ "$value" == *" | "* ]] && return 0
    return 1
}

is_choice_value() {
    local value="$1"
    shift
    for choice in "$@"; do
        if [[ "$value" == "$choice" ]]; then
            return 0
        fi
    done
    return 1
}

has_placeholder_content() {
    local file="$1"
    grep -Eiq '(^|[[:space:]])(TODO|TBD)([[:space:]]|$)|<(paste output|paste here|output|TODO|TBD)[^>]*>|paste[[:space:]-]*(output|here)|placeholder evidence|evidence for [A-Za-z0-9_-]+' "$file"
}

directory_has_placeholder_content() {
    local dir="$1"
    local evidence_file
    while IFS= read -r evidence_file; do
        if has_placeholder_content "$evidence_file"; then
            return 0
        fi
    done < <(find "$dir" -type f -size +0c -print)
    return 1
}

path_has_symlink_component() {
    local relative_path="$1"
    local current="$MANIFEST_DIR"
    local component
    local components
    IFS='/' read -r -a components <<<"$relative_path"
    for component in "${components[@]}"; do
        [[ -z "$component" || "$component" == "." ]] && continue
        current="$current/$component"
        if [[ -L "$current" ]]; then
            return 0
        fi
    done
    return 1
}

is_known_id() {
    local check_id="$1"
    required_check_ids | grep -qx "$check_id" && return 0
    optional_check_ids | grep -qx "$check_id" && return 0
    return 1
}

is_required_id() {
    local check_id="$1"
    required_check_ids | grep -qx "$check_id"
}

has_seen_id() {
    local check_id="$1"
    local seen
    for seen in "${SEEN_CHECK_IDS[@]}"; do
        [[ "$seen" == "$check_id" ]] && return 0
    done
    return 1
}

value_for_key() {
    local key="$1"
    local file="$2"
    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); found = 1 } END { if (!found) exit 1 }' "$file"
}

field_value() {
    local label="$1"
    local file="$2"
    awk -v label="$label" '
        index($0, "- " label ":") == 1 {
            sub("^- " label ": *", "")
            print
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$file"
}

require_file() {
    local context="$1"
    local file="$2"
    if [[ ! -f "$file" ]]; then
        record_error "$context" "missing file: $file"
    elif [[ ! -s "$file" ]]; then
        record_error "$context" "empty file: $file"
    fi
}

check_required_field() {
    local label="$1"
    local value

    if ! value="$(field_value "$label" "$MANUAL_FILE" 2>/dev/null)"; then
        record_error "manual-result.md" "missing field: $label"
        return
    fi

    if is_unfilled_value "$value"; then
        record_error "manual-result.md" "placeholder value for: $label"
    fi
}

check_choice_field() {
    local label="$1"
    shift
    local value

    if ! value="$(field_value "$label" "$MANUAL_FILE" 2>/dev/null)"; then
        record_error "manual-result.md" "missing field: $label"
        return
    fi

    value="$(trim_value "$value")"
    if ! is_choice_value "$value" "$@"; then
        record_error "manual-result.md" "field '$label' must be one of: $*"
    fi
}

require_yes_field() {
    local label="$1"
    check_choice_field "$label" "yes"
}

normalize_yes_no() {
    local value
    value="$(trim_value "$1")"
    case "$value" in
        yes|true) echo "yes" ;;
        no|false) echo "no" ;;
        *) echo "$value" ;;
    esac
}

verify_config() {
    require_file "validation-config.txt" "$CONFIG_FILE"
    [[ -f "$CONFIG_FILE" ]] || return

    local format metadata_redacted macos_version launchdaemon_plist signed result
    format="$(value_for_key evidenceFormat "$CONFIG_FILE" 2>/dev/null || true)"
    metadata_redacted="$(value_for_key metadataRedacted "$CONFIG_FILE" 2>/dev/null || true)"
    macos_version="$(value_for_key macOSVersion "$CONFIG_FILE" 2>/dev/null || true)"
    launchdaemon_plist="$(value_for_key launchDaemonPlist "$CONFIG_FILE" 2>/dev/null || true)"
    signed="$(value_for_key developerIDApplicationSigned "$CONFIG_FILE" 2>/dev/null || true)"
    PACKAGE_INSTALLER_USED="$(value_for_key packageInstallerUsed "$CONFIG_FILE" 2>/dev/null || true)"
    HOMEBREW_CASK_USED="$(value_for_key homebrewCaskUsed "$CONFIG_FILE" 2>/dev/null || true)"
    result="$(value_for_key result "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_MACOS_VERSION="$macos_version"
    CONFIG_LAUNCHDAEMON_PLIST="$launchdaemon_plist"
    CONFIG_RESULT="$result"

    if [[ "$format" != "smappservice-prototype-v1" ]]; then
        record_error "validation-config.txt" "evidenceFormat must be smappservice-prototype-v1"
    fi
    if [[ "$metadata_redacted" != "true" ]]; then
        record_error "validation-config.txt" "metadataRedacted must be true"
    fi

    for key in appBundleIdentifier helperLabel; do
        local keyed_value
        keyed_value="$(value_for_key "$key" "$CONFIG_FILE" 2>/dev/null || true)"
        if is_unfilled_value "$keyed_value"; then
            record_error "validation-config.txt" "$key is missing or placeholder"
        elif [[ ! "$keyed_value" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]]; then
            record_error "validation-config.txt" "$key should be a bundle-style identifier"
        fi
    done

    if [[ "$macos_version" =~ ^(macOS[[:space:]]+)?([0-9]+)(\.[0-9]+)*\+?$ ]]; then
        if [[ "${BASH_REMATCH[2]}" -lt 13 ]]; then
            record_error "validation-config.txt" "macOSVersion must be 13 or newer for SMAppService daemon evidence"
        fi
    else
        record_error "validation-config.txt" "macOSVersion must look like a macOS version, for example 15.0"
    fi

    if [[ "$launchdaemon_plist" != *"Contents/Library/LaunchDaemons/"* || "$launchdaemon_plist" != *.plist ]]; then
        record_error "validation-config.txt" "launchDaemonPlist must live under Contents/Library/LaunchDaemons and end in .plist"
    fi
    if [[ "$signed" != "true" ]]; then
        record_error "validation-config.txt" "developerIDApplicationSigned must be true for #27 evidence"
    fi
    if ! is_choice_value "$PACKAGE_INSTALLER_USED" "true" "false"; then
        record_error "validation-config.txt" "packageInstallerUsed must be true or false"
    fi
    if ! is_choice_value "$HOMEBREW_CASK_USED" "true" "false"; then
        record_error "validation-config.txt" "homebrewCaskUsed must be true or false"
    fi
    if ! is_choice_value "$result" "pass" "fail" "inconclusive"; then
        record_error "validation-config.txt" "result must be pass, fail, or inconclusive"
    fi
}

verify_manual_result() {
    require_file "manual-result.md" "$MANUAL_FILE"
    [[ -f "$MANUAL_FILE" ]] || return

    for label in \
        "Case ID" \
        "macOS" \
        "App bundle" \
        "LaunchDaemon plist" \
        "SMAppService API" \
        "App signed" \
        "Helper signed" \
        "Designated requirements recorded" \
        "Package installer used" \
        "Package signed with Developer ID Installer" \
        "Register status transition" \
        "System Settings approval confirmed" \
        "Helper bootstraps after approval" \
        "Helper bootstraps after reboot" \
        "Old helper inactive after update" \
        "Ledger compatibility or repair checked" \
        "Uninstall unloaded helper" \
        "Helper-owned Bag Mode state removed" \
        "Failure cases recorded" \
        "Homebrew cask used" \
        "Homebrew cask registers helper during install" \
        "Result"
    do
        check_required_field "$label"
    done

    require_yes_field "App signed"
    require_yes_field "Helper signed"
    require_yes_field "Designated requirements recorded"
    require_yes_field "System Settings approval confirmed"
    require_yes_field "Helper bootstraps after approval"
    require_yes_field "Helper bootstraps after reboot"
    require_yes_field "Old helper inactive after update"
    require_yes_field "Ledger compatibility or repair checked"
    require_yes_field "Uninstall unloaded helper"
    require_yes_field "Helper-owned Bag Mode state removed"
    require_yes_field "Failure cases recorded"
    check_choice_field "Result" "pass" "fail" "inconclusive"

    local manual_macos manual_result launchdaemon_plist smappservice_api status_transition package_used package_signed cask_used cask_registers
    manual_macos="$(field_value "macOS" "$MANUAL_FILE" 2>/dev/null || true)"
    manual_macos="$(trim_value "$manual_macos")"
    if [[ -n "$CONFIG_MACOS_VERSION" && "$manual_macos" != "$CONFIG_MACOS_VERSION" && "$manual_macos" != "macOS $CONFIG_MACOS_VERSION" ]]; then
        record_error "manual-result.md" "macOS field must match validation-config macOSVersion"
    fi

    manual_result="$(field_value "Result" "$MANUAL_FILE" 2>/dev/null || true)"
    manual_result="$(trim_value "$manual_result")"
    if [[ -n "$CONFIG_RESULT" && "$manual_result" != "$CONFIG_RESULT" ]]; then
        record_error "manual-result.md" "Result field must match validation-config result"
    fi

    launchdaemon_plist="$(field_value "LaunchDaemon plist" "$MANUAL_FILE" 2>/dev/null || true)"
    if [[ "$launchdaemon_plist" != *"Contents/Library/LaunchDaemons/"* || "$launchdaemon_plist" != *.plist ]]; then
        record_error "manual-result.md" "LaunchDaemon plist must live under Contents/Library/LaunchDaemons and end in .plist"
    fi
    if [[ -n "$CONFIG_LAUNCHDAEMON_PLIST" &&
          "$launchdaemon_plist" != "$CONFIG_LAUNCHDAEMON_PLIST" &&
          "$launchdaemon_plist" != *"/$CONFIG_LAUNCHDAEMON_PLIST" ]]; then
        record_error "manual-result.md" "LaunchDaemon plist field must match validation-config launchDaemonPlist"
    fi

    smappservice_api="$(field_value "SMAppService API" "$MANUAL_FILE" 2>/dev/null || true)"
    if [[ "$smappservice_api" != *"SMAppService.daemon"* ]]; then
        record_error "manual-result.md" "SMAppService API must mention SMAppService.daemon(plistName:)"
    fi

    status_transition="$(field_value "Register status transition" "$MANUAL_FILE" 2>/dev/null || true)"
    if [[ "$status_transition" != *"requiresApproval"* || "$status_transition" != *"enabled"* ]]; then
        record_error "manual-result.md" "Register status transition must include requiresApproval and enabled states"
    fi

    package_used="$(normalize_yes_no "$(field_value "Package installer used" "$MANUAL_FILE" 2>/dev/null || true)")"
    package_signed="$(normalize_yes_no "$(field_value "Package signed with Developer ID Installer" "$MANUAL_FILE" 2>/dev/null || true)")"
    if [[ "$PACKAGE_INSTALLER_USED" == "true" && "$package_used" != "yes" ]]; then
        record_error "manual-result.md" "Package installer used must be yes when validation-config packageInstallerUsed=true"
    elif [[ "$PACKAGE_INSTALLER_USED" == "false" && "$package_used" != "no" ]]; then
        record_error "manual-result.md" "Package installer used must be no when validation-config packageInstallerUsed=false"
    fi
    if [[ "$PACKAGE_INSTALLER_USED" == "true" && "$package_signed" != "yes" ]]; then
        record_error "manual-result.md" "Package signed with Developer ID Installer must be yes when a package installer is used"
    elif [[ "$PACKAGE_INSTALLER_USED" == "false" && "$package_signed" != "no" && "$package_signed" != N/A* ]]; then
        record_error "manual-result.md" "Package signed with Developer ID Installer must be N/A or no when no package installer is used"
    fi

    cask_used="$(normalize_yes_no "$(field_value "Homebrew cask used" "$MANUAL_FILE" 2>/dev/null || true)")"
    cask_registers="$(normalize_yes_no "$(field_value "Homebrew cask registers helper during install" "$MANUAL_FILE" 2>/dev/null || true)")"
    if [[ "$HOMEBREW_CASK_USED" == "true" && "$cask_used" != "yes" ]]; then
        record_error "manual-result.md" "Homebrew cask used must be yes when validation-config homebrewCaskUsed=true"
    elif [[ "$HOMEBREW_CASK_USED" == "false" && "$cask_used" != "no" ]]; then
        record_error "manual-result.md" "Homebrew cask used must be no when validation-config homebrewCaskUsed=false"
    fi
    if [[ "$HOMEBREW_CASK_USED" == "true" && "$cask_registers" != "no" ]]; then
        record_error "manual-result.md" "Homebrew cask install/upgrade must not register, bootstrap, or approve the helper"
    elif [[ "$HOMEBREW_CASK_USED" == "false" && "$cask_registers" != "no" && "$cask_registers" != N/A* ]]; then
        record_error "manual-result.md" "Homebrew cask registers helper during install must be N/A or no when no cask path is used"
    fi
}

verify_evidence_path() {
    local check_id="$1"
    local evidence_path="$2"

    if is_unfilled_value "$evidence_path"; then
        record_error "$check_id" "evidence row requires evidencePath"
        return
    fi
    if [[ "$evidence_path" == /* || "$evidence_path" == *".."* ]]; then
        record_error "$check_id" "evidencePath must be a relative path inside the evidence package"
        return
    fi
    if path_has_symlink_component "$evidence_path"; then
        record_error "$check_id" "evidencePath must not contain symlinks: $evidence_path"
        return
    fi

    local resolved_path="$MANIFEST_DIR/$evidence_path"
    if [[ -f "$resolved_path" ]]; then
        if [[ ! -s "$resolved_path" ]]; then
            record_error "$check_id" "evidence file is empty: $evidence_path"
        elif has_placeholder_content "$resolved_path"; then
            record_error "$check_id" "evidence file contains placeholder content: $evidence_path"
        fi
    elif [[ -d "$resolved_path" ]]; then
        if find "$resolved_path" -type l -print -quit | grep -q .; then
            record_error "$check_id" "evidence directory must not contain symlinks: $evidence_path"
        elif ! find "$resolved_path" -type f -size +0c -print -quit | grep -q .; then
            record_error "$check_id" "evidence directory has no non-empty files: $evidence_path"
        elif directory_has_placeholder_content "$resolved_path"; then
            record_error "$check_id" "evidence directory contains placeholder content: $evidence_path"
        fi
    else
        record_error "$check_id" "evidencePath does not exist: $evidence_path"
    fi
}

verify_manifest() {
    local header
    IFS= read -r header <"$MANIFEST_FILE" || true
    if [[ "$header" != $'checkId\tstatus\tevidencePath\tnote' ]]; then
        echo "Manifest header must be: checkId<TAB>status<TAB>evidencePath<TAB>note" >&2
        exit 2
    fi

    local row_count=0
    local line_number=1
    local line field_count check_id status evidence_path note
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        line_number=$((line_number + 1))
        [[ -z "${line:-}" ]] && continue
        row_count=$((row_count + 1))

        field_count="$(awk -F '\t' '{ print NF }' <<<"$line")"
        if [[ "$field_count" -ne 4 ]]; then
            record_error "manifest:$line_number" "row must have exactly 4 tab-separated columns"
            continue
        fi
        check_id="$(trim_value "$(awk -F '\t' '{ print $1 }' <<<"$line")")"
        status="$(trim_value "$(awk -F '\t' '{ print $2 }' <<<"$line")")"
        evidence_path="$(trim_value "$(awk -F '\t' '{ print $3 }' <<<"$line")")"
        note="$(trim_value "$(awk -F '\t' '{ print $4 }' <<<"$line")")"

        if is_unfilled_value "$check_id"; then
            record_error "manifest:$line_number" "checkId is missing or placeholder"
            continue
        fi
        if ! is_known_id "$check_id"; then
            record_error "$check_id" "unknown checkId"
            continue
        fi
        if has_seen_id "$check_id"; then
            record_error "$check_id" "duplicate manifest row"
            continue
        fi
        SEEN_CHECK_IDS+=("$check_id")
        if [[ "$check_id" == "package-installer-signing" ]]; then
            PACKAGE_INSTALLER_STATUS="$status"
        elif [[ "$check_id" == "homebrew-cask-semantics" ]]; then
            HOMEBREW_CASK_STATUS="$status"
        fi

        if is_required_id "$check_id"; then
            if [[ "$status" != "evidence" ]]; then
                record_error "$check_id" "required check must use status evidence"
                continue
            fi
            verify_evidence_path "$check_id" "$evidence_path"
        else
            case "$status" in
                evidence)
                    verify_evidence_path "$check_id" "$evidence_path"
                    ;;
                n/a)
                    if is_unfilled_value "$note"; then
                        record_error "$check_id" "n/a row requires an explicit note"
                    fi
                    ;;
                *)
                    record_error "$check_id" "optional check status must be evidence or n/a"
                    ;;
            esac
        fi
    done < <(tail -n +2 "$MANIFEST_FILE")

    if [[ "$row_count" -eq 0 ]]; then
        record_error "manifest" "manifest has no evidence rows"
    fi

    local required_id
    while IFS= read -r required_id; do
        if ! has_seen_id "$required_id"; then
            record_error "$required_id" "missing required manifest row"
        fi
    done < <(required_check_ids)

    if [[ "$PACKAGE_INSTALLER_USED" == "true" && "$PACKAGE_INSTALLER_STATUS" != "evidence" ]]; then
        record_error "package-installer-signing" "packageInstallerUsed=true requires package installer signing evidence"
    fi
    if [[ "$HOMEBREW_CASK_USED" == "true" && "$HOMEBREW_CASK_STATUS" != "evidence" ]]; then
        record_error "homebrew-cask-semantics" "homebrewCaskUsed=true requires cask install/upgrade/uninstall evidence"
    fi
}

verify_config
verify_manual_result
verify_manifest

if [[ "$case_errors" -ne 0 ]]; then
    echo "Helper service prototype evidence verification failed with $case_errors error(s)." >&2
    exit 1
fi

echo "Helper service prototype evidence verification passed."
