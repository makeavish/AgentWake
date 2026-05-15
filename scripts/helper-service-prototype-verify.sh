#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/helper-service-prototype-verify.sh ..." >&2
    exit 2
fi
set -euo pipefail

MANIFEST_FILE=""
SEEN_CHECK_IDS=("__sentinel__")
case_errors=0
PACKAGE_INSTALLER_USED=""
HOMEBREW_CASK_USED=""
PACKAGE_INSTALLER_STATUS=""
HOMEBREW_CASK_STATUS=""
SMAPPSERVICE_REJECTION_STATUS=""
CONFIG_MACOS_VERSION=""
CONFIG_LAUNCHDAEMON_PLIST=""
CONFIG_HELPER_INSTALL_PATH=""
CONFIG_DEVELOPER_ID_APPLICATION_SIGNED=""
CONFIG_RESULT=""

usage() {
    cat <<'EOF'
Usage: scripts/helper-service-prototype-verify.sh --manifest PATH

Checks the helper prototype evidence package for #27. This
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
app-bundle-or-install-layout
launchdaemon-plist
app-signing-or-auth-model
helper-signing-or-auth-model
caller-auth-model
fixed-command-api
spctl-or-gatekeeper-assessment
helper-install-or-register
helper-status-after-approval
admin-approval-or-password-flow
helper-bootstrap-after-approval
post-reboot-helper-bootstrap
root-ledger-schema-and-permissions
root-ledger-ownership-sample
helper-update-old-inactive
helper-update-ledger-compatibility
helper-repair-conflict
helper-uninstall
helper-uninstall-state-cleanup
cli-helper-status-repair-uninstall
failure-unpaired-caller
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
smappservice-rejection
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

    local format metadata_redacted macos_version launchdaemon_plist signed result helper_install_path local_auth_model
    format="$(value_for_key evidenceFormat "$CONFIG_FILE" 2>/dev/null || true)"
    metadata_redacted="$(value_for_key metadataRedacted "$CONFIG_FILE" 2>/dev/null || true)"
    macos_version="$(value_for_key macOSVersion "$CONFIG_FILE" 2>/dev/null || true)"
    launchdaemon_plist="$(value_for_key launchDaemonPlist "$CONFIG_FILE" 2>/dev/null || true)"
    helper_install_path="$(value_for_key helperInstallPath "$CONFIG_FILE" 2>/dev/null || true)"
    local_auth_model="$(value_for_key localAuthModel "$CONFIG_FILE" 2>/dev/null || true)"
    signed="$(value_for_key developerIDApplicationSigned "$CONFIG_FILE" 2>/dev/null || true)"
    PACKAGE_INSTALLER_USED="$(value_for_key packageInstallerUsed "$CONFIG_FILE" 2>/dev/null || true)"
    HOMEBREW_CASK_USED="$(value_for_key homebrewCaskUsed "$CONFIG_FILE" 2>/dev/null || true)"
    result="$(value_for_key result "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_MACOS_VERSION="$macos_version"
    CONFIG_LAUNCHDAEMON_PLIST="$launchdaemon_plist"
    CONFIG_HELPER_INSTALL_PATH="$helper_install_path"
    CONFIG_DEVELOPER_ID_APPLICATION_SIGNED="$signed"
    CONFIG_RESULT="$result"

    if [[ "$format" != "helper-prototype-v1" ]]; then
        record_error "validation-config.txt" "evidenceFormat must be helper-prototype-v1"
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

    if ! is_choice_value "$helper_install_path" "smappservice" "launchdaemon-fallback"; then
        record_error "validation-config.txt" "helperInstallPath must be smappservice or launchdaemon-fallback"
    fi
    if is_unfilled_value "$local_auth_model"; then
        record_error "validation-config.txt" "localAuthModel is missing or placeholder"
    fi
    if [[ "$helper_install_path" == "smappservice" ]]; then
        if [[ "$launchdaemon_plist" != *"Contents/Library/LaunchDaemons/"* || "$launchdaemon_plist" != *.plist ]]; then
            record_error "validation-config.txt" "launchDaemonPlist must live under Contents/Library/LaunchDaemons and end in .plist for helperInstallPath=smappservice"
        fi
    elif [[ "$helper_install_path" == "launchdaemon-fallback" ]]; then
        if [[ "$launchdaemon_plist" != /Library/LaunchDaemons/*.plist ]]; then
            record_error "validation-config.txt" "launchDaemonPlist must be an installed /Library/LaunchDaemons plist for helperInstallPath=launchdaemon-fallback"
        fi
    fi
    if ! is_choice_value "$signed" "true" "false"; then
        record_error "validation-config.txt" "developerIDApplicationSigned must be true or false"
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
        "Helper install path" \
        "Helper install API/path" \
        "App signed" \
        "Helper signed" \
        "Local auth model recorded" \
        "Developer ID designated requirements recorded" \
        "Package installer used" \
        "Package signed with Developer ID Installer" \
        "Install/status transition" \
        "Admin approval/password flow confirmed" \
        "Helper bootstraps after approval" \
        "Helper bootstraps after reboot" \
        "Old helper inactive after update" \
        "Ledger compatibility or repair checked" \
        "Uninstall unloaded helper" \
        "Helper-owned Closed-Lid Mode state removed" \
        "Failure cases recorded" \
        "Homebrew cask used" \
        "Homebrew cask registers helper during install" \
        "Result"
    do
        check_required_field "$label"
    done

    require_yes_field "App signed"
    require_yes_field "Helper signed"
    require_yes_field "Local auth model recorded"
    require_yes_field "Admin approval/password flow confirmed"
    require_yes_field "Helper bootstraps after approval"
    require_yes_field "Helper bootstraps after reboot"
    require_yes_field "Old helper inactive after update"
    require_yes_field "Ledger compatibility or repair checked"
    require_yes_field "Uninstall unloaded helper"
    require_yes_field "Helper-owned Closed-Lid Mode state removed"
    require_yes_field "Failure cases recorded"
    check_choice_field "Result" "pass" "fail" "inconclusive"

    local manual_macos manual_result launchdaemon_plist helper_install_api helper_install_path status_transition package_used package_signed cask_used cask_registers developer_id_requirements
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
    if [[ -n "$CONFIG_LAUNCHDAEMON_PLIST" &&
          "$launchdaemon_plist" != "$CONFIG_LAUNCHDAEMON_PLIST" &&
          "$launchdaemon_plist" != *"/$CONFIG_LAUNCHDAEMON_PLIST" ]]; then
        record_error "manual-result.md" "LaunchDaemon plist field must match validation-config launchDaemonPlist"
    fi

    helper_install_path="$(field_value "Helper install path" "$MANUAL_FILE" 2>/dev/null || true)"
    helper_install_path="$(trim_value "$helper_install_path")"
    if ! is_choice_value "$helper_install_path" "smappservice" "launchdaemon-fallback"; then
        record_error "manual-result.md" "Helper install path must be smappservice or launchdaemon-fallback"
    elif [[ -n "$CONFIG_HELPER_INSTALL_PATH" && "$helper_install_path" != "$CONFIG_HELPER_INSTALL_PATH" ]]; then
        record_error "manual-result.md" "Helper install path field must match validation-config helperInstallPath"
    fi

    helper_install_api="$(field_value "Helper install API/path" "$MANUAL_FILE" 2>/dev/null || true)"
    helper_install_api="$(trim_value "$helper_install_api")"
    if is_unfilled_value "$helper_install_api"; then
        record_error "manual-result.md" "Helper install API/path is missing or placeholder"
    elif [[ "$helper_install_path" == "smappservice" && "$helper_install_api" != *"SMAppService.daemon"* ]]; then
        record_error "manual-result.md" "Helper install API/path must mention SMAppService.daemon(plistName:) when Helper install path is smappservice"
    fi

    status_transition="$(field_value "Install/status transition" "$MANUAL_FILE" 2>/dev/null || true)"
    if is_unfilled_value "$status_transition"; then
        record_error "manual-result.md" "Install/status transition is missing or placeholder"
    elif [[ "$helper_install_path" == "smappservice" &&
          ( "$status_transition" != *"requiresApproval"* || "$status_transition" != *"enabled"* ) ]]; then
        record_error "manual-result.md" "Install/status transition must include requiresApproval and enabled states for smappservice"
    fi

    developer_id_requirements="$(normalize_yes_no "$(field_value "Developer ID designated requirements recorded" "$MANUAL_FILE" 2>/dev/null || true)")"
    if [[ "$CONFIG_DEVELOPER_ID_APPLICATION_SIGNED" == "true" && "$developer_id_requirements" != "yes" ]]; then
        record_error "manual-result.md" "Developer ID designated requirements recorded must be yes when validation-config developerIDApplicationSigned=true"
    elif [[ "$CONFIG_DEVELOPER_ID_APPLICATION_SIGNED" == "false" && "$developer_id_requirements" != "no" && "$developer_id_requirements" != N/A* ]]; then
        record_error "manual-result.md" "Developer ID designated requirements recorded must be no or N/A when validation-config developerIDApplicationSigned=false"
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
    local line field_count check_id row_status evidence_path note
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
        row_status="$(trim_value "$(awk -F '\t' '{ print $2 }' <<<"$line")")"
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
            PACKAGE_INSTALLER_STATUS="$row_status"
        elif [[ "$check_id" == "homebrew-cask-semantics" ]]; then
            HOMEBREW_CASK_STATUS="$row_status"
        elif [[ "$check_id" == "smappservice-rejection" ]]; then
            SMAPPSERVICE_REJECTION_STATUS="$row_status"
        fi

        if is_required_id "$check_id"; then
            if [[ "$row_status" != "evidence" ]]; then
                record_error "$check_id" "required check must use status evidence"
                continue
            fi
            verify_evidence_path "$check_id" "$evidence_path"
        else
            case "$row_status" in
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
    if [[ "$CONFIG_HELPER_INSTALL_PATH" == "launchdaemon-fallback" && "$SMAPPSERVICE_REJECTION_STATUS" != "evidence" ]]; then
        record_error "smappservice-rejection" "helperInstallPath=launchdaemon-fallback requires evidence of the SMAppService rejection or incompatibility that justifies fallback"
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
