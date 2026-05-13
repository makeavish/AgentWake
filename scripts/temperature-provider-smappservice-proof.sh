#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/temperature-provider-smappservice-proof.sh ..." >&2
    exit 2
fi
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/temperature-provider-smappservice-proof.sh --output-dir DIR [--case-id ID]
       scripts/temperature-provider-smappservice-proof.sh --output-dir DIR --register --i-understand-this-registers-provider
       scripts/temperature-provider-smappservice-proof.sh --output-dir DIR --capture-post-approval
       scripts/temperature-provider-smappservice-proof.sh --output-dir DIR --capture-unregister --i-understand-this-registers-provider

Builds a no-membership SMAppService temperature-provider proof-attempt package
for #25. The default mode is non-mutating: it builds an ad-hoc signed app and
LaunchDaemon helper that will run one timeout-bounded provider sample when
registered and approved. The default source is powermetrics; set
CLAWSHELL_TEMPERATURE_PROVIDER_SOURCE=ioreg-smc for the diagnostic I/O Registry
SMC endpoint source.

--register calls SMAppService and can change local helper state. Use it only
during an intentional #25 prototype run.

--capture-post-approval is non-mutating. Run it against the same existing
artifact directory after any required System Settings approval and a 15 second
wait to append helper runtime, provider output, status, launchctl, and log
evidence.

--capture-unregister is mutating. Run it against the same existing artifact
directory to call SMAppService unregister and append cleanup status evidence.
USAGE
}

OUTPUT_DIR=""
CASE_ID=""
REGISTER=false
CAPTURE_POST_APPROVAL=false
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
        --capture-post-approval)
            CAPTURE_POST_APPROVAL=true
            shift
            ;;
        --capture-unregister)
            CAPTURE_UNREGISTER=true
            shift
            ;;
        --i-understand-this-registers-provider)
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
[[ "$CAPTURE_POST_APPROVAL" == true ]] && MODE_COUNT=$((MODE_COUNT + 1))
[[ "$CAPTURE_UNREGISTER" == true ]] && MODE_COUNT=$((MODE_COUNT + 1))
if [[ "$MODE_COUNT" -gt 1 ]]; then
    echo "Use only one of --register, --capture-post-approval, or --capture-unregister per run." >&2
    exit 64
fi
if [[ ( "$REGISTER" == true || "$CAPTURE_UNREGISTER" == true ) && "$ALLOW_MUTATION" != true ]]; then
    echo "--register/--capture-unregister requires --i-understand-this-registers-provider" >&2
    exit 64
fi
APPEND_CAPTURE=false
CAPTURE_ACTION_NAME="Post-approval capture"
if [[ "$CAPTURE_POST_APPROVAL" == true || "$CAPTURE_UNREGISTER" == true ]]; then
    APPEND_CAPTURE=true
fi
if [[ "$CAPTURE_UNREGISTER" == true ]]; then
    CAPTURE_ACTION_NAME="Unregister capture"
fi
if [[ -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ]]; then
    echo "Output path exists but is not a directory: $OUTPUT_DIR" >&2
    exit 73
fi
OUTPUT_HAS_CONTENT=false
if [[ -d "$OUTPUT_DIR" && -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    OUTPUT_HAS_CONTENT=true
fi
REGISTER_EXISTING_ARTIFACT=false
if [[ "$REGISTER" == true ]]; then
    REGISTER_EXISTING_ARTIFACT=true
    CAPTURE_ACTION_NAME="Register capture"
fi
EXISTING_ARTIFACT_MODE=false
if [[ "$APPEND_CAPTURE" == true || "$REGISTER_EXISTING_ARTIFACT" == true ]]; then
    EXISTING_ARTIFACT_MODE=true
fi
if [[ "$EXISTING_ARTIFACT_MODE" == true && ! -d "$OUTPUT_DIR" ]]; then
    echo "$CAPTURE_ACTION_NAME requires an existing artifact directory: $OUTPUT_DIR" >&2
    exit 73
fi
if [[ "$EXISTING_ARTIFACT_MODE" == true && -L "$OUTPUT_DIR" ]]; then
    echo "$CAPTURE_ACTION_NAME requires a real artifact directory, not a symlink: $OUTPUT_DIR" >&2
    exit 73
fi
if [[ "$APPEND_CAPTURE" == false && "$REGISTER_EXISTING_ARTIFACT" == false && "$OUTPUT_HAS_CONTENT" == true ]]; then
    echo "Output directory is not empty: $OUTPUT_DIR" >&2
    exit 73
fi
if [[ "$EXISTING_ARTIFACT_MODE" == true && "$OUTPUT_HAS_CONTENT" == false ]]; then
    echo "$CAPTURE_ACTION_NAME requires a non-empty artifact directory: $OUTPUT_DIR" >&2
    exit 73
fi

PROVIDER_SOURCE=${CLAWSHELL_TEMPERATURE_PROVIDER_SOURCE:-powermetrics}
TIMEOUT_SECONDS=${CLAWSHELL_TEMPERATURE_PROVIDER_TIMEOUT_SECONDS:-1}
SAMPLE_RATE_MS=${CLAWSHELL_TEMPERATURE_PROVIDER_SAMPLE_RATE_MS:-1000}
SHOW_INITIAL_USAGE=${CLAWSHELL_TEMPERATURE_PROVIDER_SHOW_INITIAL_USAGE:-true}
POWERMETRICS_SAMPLERS=${CLAWSHELL_TEMPERATURE_PROVIDER_POWERMETRICS_SAMPLERS:-thermal}
FRESHNESS_SECONDS=${CLAWSHELL_TEMPERATURE_PROVIDER_FRESHNESS_SECONDS:-10}
ACTIVE_CADENCE_SECONDS=${CLAWSHELL_TEMPERATURE_PROVIDER_ACTIVE_CADENCE_SECONDS:-5}
IDLE_CADENCE_SECONDS=${CLAWSHELL_TEMPERATURE_PROVIDER_IDLE_CADENCE_SECONDS:-30}

require_positive_integer() {
    local name="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
        echo "$name must be a positive integer" >&2
        exit 64
    fi
}

require_bool() {
    local name="$1"
    local value="$2"
    case "$value" in
        true|false) ;;
        *)
            echo "$name must be true or false" >&2
            exit 64
            ;;
    esac
}

require_powermetrics_samplers() {
    local name="$1"
    local value="$2"
    local sampler
    if [[ "$value" == *[$'\n\r\t']* ]]; then
        echo "$name must not contain control characters" >&2
        exit 64
    fi
    if [[ -z "$value" || "$value" == *, || "$value" == ,* || "$value" == *,,* ]]; then
        echo "$name must be a comma-separated list of supported powermetrics samplers" >&2
        exit 64
    fi
    IFS=',' read -r -a samplers <<<"$value"
    for sampler in "${samplers[@]}"; do
        case "$sampler" in
            tasks|battery|network|disk|interrupts|cpu_power|thermal|sfi|gpu_power|ane_power|all|default) ;;
            *)
                echo "$name contains unsupported powermetrics sampler: $sampler" >&2
                exit 64
                ;;
        esac
    done
}

require_provider_source() {
    local name="$1"
    local value="$2"
    case "$value" in
        powermetrics|ioreg-smc) ;;
        *)
            echo "$name must be one of: powermetrics, ioreg-smc" >&2
            exit 64
            ;;
    esac
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
    if ! [[ "$value" =~ ^com[.]makeavish[.]ClawShell[.]TemperatureProviderPrototype([.][A-Za-z][A-Za-z0-9]{0,31})?[.]daemon$ ]]; then
        echo "$name must be a ClawShell temperature provider helper label" >&2
        exit 73
    fi
}

require_provider_source "CLAWSHELL_TEMPERATURE_PROVIDER_SOURCE" "$PROVIDER_SOURCE"
require_positive_integer "CLAWSHELL_TEMPERATURE_PROVIDER_TIMEOUT_SECONDS" "$TIMEOUT_SECONDS"
require_positive_integer "CLAWSHELL_TEMPERATURE_PROVIDER_SAMPLE_RATE_MS" "$SAMPLE_RATE_MS"
require_bool "CLAWSHELL_TEMPERATURE_PROVIDER_SHOW_INITIAL_USAGE" "$SHOW_INITIAL_USAGE"
if [[ "$PROVIDER_SOURCE" == "powermetrics" ]]; then
    require_powermetrics_samplers "CLAWSHELL_TEMPERATURE_PROVIDER_POWERMETRICS_SAMPLERS" "$POWERMETRICS_SAMPLERS"
else
    POWERMETRICS_SAMPLERS="not-used"
fi
if [[ -n "${CLAWSHELL_TEMPERATURE_PROVIDER_ID_SUFFIX:-}" ]]; then
    require_identity_suffix "CLAWSHELL_TEMPERATURE_PROVIDER_ID_SUFFIX" "$CLAWSHELL_TEMPERATURE_PROVIDER_ID_SUFFIX"
fi
require_positive_integer "CLAWSHELL_TEMPERATURE_PROVIDER_FRESHNESS_SECONDS" "$FRESHNESS_SECONDS"
require_positive_integer "CLAWSHELL_TEMPERATURE_PROVIDER_ACTIVE_CADENCE_SECONDS" "$ACTIVE_CADENCE_SECONDS"
require_positive_integer "CLAWSHELL_TEMPERATURE_PROVIDER_IDLE_CADENCE_SECONDS" "$IDLE_CADENCE_SECONDS"

if [[ -z "$CASE_ID" ]]; then
    case "$PROVIDER_SOURCE" in
        ioreg-smc)
            CASE_ID="apple-silicon-ioreg-smc-smappservice"
            ;;
        *)
            CASE_ID="apple-silicon-powermetrics-smappservice"
            ;;
    esac
fi

if [[ "$EXISTING_ARTIFACT_MODE" == false ]]; then
    mkdir -p "$OUTPUT_DIR"
fi
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

if [[ "$EXISTING_ARTIFACT_MODE" == true ]]; then
    existing_config_file="$OUTPUT_DIR/validation-config.txt"
    if [[ -L "$existing_config_file" || ( -e "$existing_config_file" && ! -f "$existing_config_file" ) ]]; then
        echo "$CAPTURE_ACTION_NAME requires regular artifact file path: $existing_config_file" >&2
        exit 73
    fi
    if [[ ! -f "$existing_config_file" ]]; then
        echo "$CAPTURE_ACTION_NAME missing required artifact file path: $existing_config_file" >&2
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

BASE_BUNDLE_ID="com.makeavish.ClawShell.TemperatureProviderPrototype"
BASE_HELPER_LABEL="com.makeavish.ClawShell.TemperatureProviderPrototype"
IDENTITY_SUFFIX="${CLAWSHELL_TEMPERATURE_PROVIDER_ID_SUFFIX:-}"
if [[ "$EXISTING_ARTIFACT_MODE" == true && -f "$OUTPUT_DIR/validation-config.txt" ]]; then
    HELPER_LABEL="$(config_value helperLabel "$OUTPUT_DIR/validation-config.txt" || true)"
    BUNDLE_ID="$(config_value appBundleIdentifier "$OUTPUT_DIR/validation-config.txt" || true)"
    IDENTITY_SUFFIX="$(config_value identitySuffix "$OUTPUT_DIR/validation-config.txt" || true)"
    if [[ -z "$HELPER_LABEL" ]]; then
        echo "$CAPTURE_ACTION_NAME missing required helperLabel in validation config" >&2
        exit 73
    fi
    require_helper_label "helperLabel" "$HELPER_LABEL"
    if [[ -n "$IDENTITY_SUFFIX" ]]; then
        require_identity_suffix "identitySuffix" "$IDENTITY_SUFFIX"
    fi
    if [[ -z "$BUNDLE_ID" ]]; then
        BUNDLE_ID="$BASE_BUNDLE_ID"
    fi
else
    if [[ -z "$IDENTITY_SUFFIX" ]]; then
        IDENTITY_SUFFIX="$(derive_identity_suffix)"
    fi
    require_identity_suffix "CLAWSHELL_TEMPERATURE_PROVIDER_ID_SUFFIX" "$IDENTITY_SUFFIX"
    BUNDLE_ID="$BASE_BUNDLE_ID.$IDENTITY_SUFFIX"
    HELPER_LABEL="$BASE_HELPER_LABEL.$IDENTITY_SUFFIX.daemon"
fi
APP_NAME="ClawShellTemperatureProviderPrototype"
HELPER_NAME="ClawShellTemperatureProviderPrototypeDaemon"
PLIST_NAME="$HELPER_LABEL.plist"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
LAUNCHD_DIR="$CONTENTS_DIR/Library/LaunchDaemons"
RUNTIME_DIR="$OUTPUT_DIR/runtime"
SOURCE_DIR="$OUTPUT_DIR/source-package"
EVIDENCE_DIR="$OUTPUT_DIR/evidence"
CONFIG_FILE="$OUTPUT_DIR/validation-config.txt"
MANIFEST_FILE="$OUTPUT_DIR/provider-manifest.tsv"

if [[ "$EXISTING_ARTIFACT_MODE" == false ]]; then
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
    {
        printf 'command='
        printf '%q' "$1"
        shift
        for part in "$@"; do
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

capture_file_snapshot() {
    local name="$1"
    local source_file="$2"
    local out="$EVIDENCE_DIR/$name.txt"
    local status_file="$EVIDENCE_DIR/$name.status"
    local start finish status
    start="$(date +%s)"
    status=0
    {
        printf '$ test -f %q && test -s %q && sed -n 1,240p %q\n' "$source_file" "$source_file" "$source_file"
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
            sed -n '1,240p' "$source_file" || status=1
        else
            echo "missingOrEmpty=$source_file"
            status=1
        fi
    } >"$out" 2>&1
    finish="$(date +%s)"
    {
        echo "command=file-snapshot $source_file"
        echo "exitCode=$status"
        echo "durationSeconds=$(( finish - start ))"
    } >"$status_file"
    return "$status"
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
    if [[ "$REGISTER_EXISTING_ARTIFACT" == true ]]; then
        target="$OUTPUT_DIR/register-capture.md"
    elif [[ "$CAPTURE_UNREGISTER" == true ]]; then
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

require_existing_artifact() {
    for required_path in \
        "$APP_DIR" \
        "$CONTENTS_DIR" \
        "$MACOS_DIR" \
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
    for required_path in "$CONFIG_FILE" "$MANIFEST_FILE" "$LAUNCHD_DIR/$PLIST_NAME"; do
        if [[ -L "$required_path" || ( -e "$required_path" && ! -f "$required_path" ) ]]; then
            echo "$CAPTURE_ACTION_NAME requires regular artifact file path: $required_path" >&2
            exit 73
        fi
        if [[ ! -f "$required_path" ]]; then
            echo "$CAPTURE_ACTION_NAME missing required artifact file path: $required_path" >&2
            exit 73
        fi
    done
    plist_label="$(plutil -extract Label raw -o - "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true)"
    if [[ "$plist_label" != "$HELPER_LABEL" ]]; then
        echo "$CAPTURE_ACTION_NAME requires LaunchDaemon Label to match helperLabel: $LAUNCHD_DIR/$PLIST_NAME" >&2
        exit 73
    fi
    if [[ ! -w "$CONFIG_FILE" ]]; then
        echo "$CAPTURE_ACTION_NAME requires writable validation config: $CONFIG_FILE" >&2
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
    require_existing_artifact
    require_writable_capture_targets \
        temperature-provider-status-after-approval \
        helper-ownership-context \
        numeric-temperature-output \
        permission-behavior \
        timeout-enforcement \
        launchctl-status \
        logs

    capture "temperature-provider-status-after-approval" "$MACOS_DIR/$APP_NAME" status || true
    assert_controller_plist_name "temperature-provider-status-after-approval"
    capture "launchctl-status" launchctl print "system/$HELPER_LABEL" || true
    capture_file_snapshot "helper-ownership-context" "$RUNTIME_DIR/provider.log" || true
    capture_file_snapshot "numeric-temperature-output" "$RUNTIME_DIR/numeric-temperature-output.txt" || true
    capture_file_snapshot "permission-behavior" "$RUNTIME_DIR/numeric-temperature-output.status" || true
    capture_file_snapshot "timeout-enforcement" "$RUNTIME_DIR/numeric-temperature-output.status" || true
    capture "logs" log show --style syslog --last "${CLAWSHELL_TEMPERATURE_PROVIDER_LOG_LAST:-10m}" --predicate "process == \"$HELPER_NAME\" || eventMessage CONTAINS \"$HELPER_LABEL\"" || true

    config_set_key "postApprovalCaptureAttempted" "true"

    cat >"$OUTPUT_DIR/post-approval-capture.md" <<EOF
# Temperature Provider Post-Approval Capture

This non-mutating capture appended status and helper runtime evidence to the
existing SMAppService temperature-provider artifact.

Captured files:

- \`evidence/temperature-provider-status-after-approval.txt\`
- \`evidence/launchctl-status.txt\`
- \`evidence/helper-ownership-context.txt\`
- \`evidence/numeric-temperature-output.txt\`
- \`evidence/permission-behavior.txt\`
- \`evidence/timeout-enforcement.txt\`
- \`evidence/logs.txt\`

This command does not promote manifest rows automatically. Review the captured
output, update the manifest and manual result deliberately, then run the
verifier before attaching the artifact to #25.
EOF

    echo "Post-approval provider evidence appended to $OUTPUT_DIR"
    echo "Run scripts/temperature-provider-proof-verify.sh --manifest $MANIFEST_FILE to inspect remaining TODO rows."
}

capture_register_status() {
    require_existing_artifact
    require_writable_capture_targets \
        temperature-provider-status-before-register \
        provider-register \
        temperature-provider-status-after-register

    capture "temperature-provider-status-before-register" "$MACOS_DIR/$APP_NAME" status || true
    assert_controller_plist_name "temperature-provider-status-before-register"
    capture "provider-register" "$MACOS_DIR/$APP_NAME" register || true
    capture "temperature-provider-status-after-register" "$MACOS_DIR/$APP_NAME" status || true
    assert_controller_plist_name "temperature-provider-status-after-register"

    config_set_key "registerAttempted" "true"
    config_set_key "registerCaptureAttempted" "true"

    cat >"$OUTPUT_DIR/register-capture.md" <<EOF
# Temperature Provider Register Capture

This mutating capture appended SMAppService registration evidence to the
existing temperature-provider artifact by calling register from the same app
bundle.

Captured files:

- \`evidence/temperature-provider-status-before-register.txt\`
- \`evidence/provider-register.txt\`
- \`evidence/temperature-provider-status-after-register.txt\`

This command does not promote manifest rows automatically. After macOS approval,
wait at least 15 seconds, then run \`--capture-post-approval\` against the same
artifact.
EOF

    echo "Register provider evidence appended to $OUTPUT_DIR"
    echo "After approval, wait at least 15 seconds, then run --capture-post-approval against the same artifact."
}

capture_unregister_status() {
    require_existing_artifact
    require_writable_capture_targets \
        temperature-provider-status-before-unregister \
        provider-unregister \
        temperature-provider-status-after-unregister \
        launchctl-status-after-unregister \
        logs-after-unregister

    capture "temperature-provider-status-before-unregister" "$MACOS_DIR/$APP_NAME" status || true
    assert_controller_plist_name "temperature-provider-status-before-unregister"
    capture "provider-unregister" "$MACOS_DIR/$APP_NAME" unregister || true
    capture "temperature-provider-status-after-unregister" "$MACOS_DIR/$APP_NAME" status || true
    assert_controller_plist_name "temperature-provider-status-after-unregister"
    capture "launchctl-status-after-unregister" launchctl print "system/$HELPER_LABEL" || true
    capture "logs-after-unregister" log show --style syslog --last "${CLAWSHELL_TEMPERATURE_PROVIDER_LOG_LAST:-10m}" --predicate "process == \"$HELPER_NAME\" || eventMessage CONTAINS \"$HELPER_LABEL\"" || true

    config_set_key "unregisterAttempted" "true"
    config_set_key "unregisterCaptureAttempted" "true"

    cat >"$OUTPUT_DIR/unregister-capture.md" <<EOF
# Temperature Provider Unregister Capture

This mutating capture appended cleanup evidence to the existing SMAppService
temperature-provider artifact by calling SMAppService unregister from the same
app bundle.

Captured files:

- \`evidence/temperature-provider-status-before-unregister.txt\`
- \`evidence/provider-unregister.txt\`
- \`evidence/temperature-provider-status-after-unregister.txt\`
- \`evidence/launchctl-status-after-unregister.txt\`
- \`evidence/logs-after-unregister.txt\`

This command does not promote manifest rows automatically. Review the captured
output before using it as cleanup evidence.
EOF

    echo "Unregister provider evidence appended to $OUTPUT_DIR"
    echo "Run scripts/temperature-provider-proof-verify.sh --manifest $MANIFEST_FILE to inspect remaining TODO rows."
}

xml_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    printf '%s' "$value"
}

write_package_manifest() {
    cat >"$SOURCE_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClawShellTemperatureProviderPrototypePackage",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ClawShellTemperatureProviderPrototype",
            targets: ["ClawShellTemperatureProviderPrototype"]
        ),
        .executable(
            name: "ClawShellTemperatureProviderPrototypeDaemon",
            targets: ["ClawShellTemperatureProviderPrototypeDaemon"]
        )
    ],
    targets: [
        .executableTarget(name: "ClawShellTemperatureProviderPrototype"),
        .executableTarget(name: "ClawShellTemperatureProviderPrototypeDaemon")
    ]
)
SWIFT
}

write_controller_source() {
    mkdir -p "$SOURCE_DIR/Sources/ClawShellTemperatureProviderPrototype"
    cat >"$SOURCE_DIR/Sources/ClawShellTemperatureProviderPrototype/main.swift" <<SWIFT
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
    mkdir -p "$SOURCE_DIR/Sources/ClawShellTemperatureProviderPrototypeDaemon"
    cat >"$SOURCE_DIR/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" <<'SWIFT'
import Dispatch
import Foundation
import Darwin

func argumentValue(after option: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: option) else {
        return nil
    }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else {
        return nil
    }
    return arguments[valueIndex]
}

func write(_ text: String, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.data(using: .utf8)?.write(to: url, options: .atomic)
}

func append(_ text: String, to path: String?) {
    guard let path else {
        return
    }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: path),
       let handle = try? FileHandle(forWritingTo: url) {
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.close()
    } else {
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}

func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

let logPath = argumentValue(after: "--log")
let outputPath = argumentValue(after: "--sample-output")
let statusPath = argumentValue(after: "--sample-status")
let providerSource = argumentValue(after: "--provider-source") ?? "powermetrics"
let timeoutSeconds = Int(argumentValue(after: "--timeout-seconds") ?? "1") ?? 1
let sampleRateMs = Int(argumentValue(after: "--sample-rate-ms") ?? "1000") ?? 1000
let powermetricsSamplers = argumentValue(after: "--powermetrics-samplers") ?? "thermal"
let showInitialUsage = CommandLine.arguments.contains("--show-initial-usage")
let powermetricsPath = "/usr/bin/powermetrics"
let ioregPath = "/usr/sbin/ioreg"
let outputByteLimit = 2_000_000
let commandPath: String
let commandArguments: [String]
switch providerSource {
case "ioreg-smc":
    commandPath = ioregPath
    commandArguments = ["-r", "-c", "AppleSMCKeysEndpoint", "-l"]
default:
    commandPath = powermetricsPath
    var arguments = ["-n", "1", "-i", "\(sampleRateMs)", "--samplers", powermetricsSamplers]
    if showInitialUsage {
        arguments.insert("--show-initial-usage", at: 0)
    }
    commandArguments = arguments
}
let started = Date()
var timedOut = false
var exitCode = 127
var runError = ""
var stdoutText = ""
var stderrText = ""
var stdoutTruncated = false
var stderrTruncated = false
var stdoutByteCount = 0
var stderrByteCount = 0

func readBoundedData(from url: URL, limit: Int) -> (Data, Bool) {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
        return (Data(), false)
    }
    defer {
        try? handle.close()
    }
    let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
    if data.count > limit {
        return (Data(data.prefix(limit)), true)
    }
    return (data, false)
}

if FileManager.default.isExecutableFile(atPath: commandPath) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: commandPath)
    process.arguments = commandArguments

    do {
        let tempDirectory = FileManager.default.temporaryDirectory
        let stdoutURL = tempDirectory.appendingPathComponent("ClawShellTemperatureProvider-\(UUID().uuidString)-stdout")
        let stderrURL = tempDirectory.appendingPathComponent("ClawShellTemperatureProvider-\(UUID().uuidString)-stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            group.wait()
        }
        try? stdoutHandle.close()
        try? stderrHandle.close()
        let stdoutData = readBoundedData(from: stdoutURL, limit: outputByteLimit)
        let stderrData = readBoundedData(from: stderrURL, limit: outputByteLimit)
        exitCode = Int(process.terminationStatus)
        stdoutByteCount = stdoutData.0.count
        stderrByteCount = stderrData.0.count
        stdoutTruncated = stdoutData.1
        stderrTruncated = stderrData.1
        stdoutText = String(decoding: stdoutData.0, as: UTF8.self)
        stderrText = String(decoding: stderrData.0, as: UTF8.self)
    } catch {
        runError = String(describing: error)
        exitCode = 126
    }
} else {
    runError = "\(providerSource) command missing at \(commandPath)"
}

let finished = Date()
let combinedOutput = stdoutText + "\n" + stderrText
let numericTemperaturePatterns = [
    #"-?\d+(\.\d+)?([ \t]*°C|[ \t]+(celsius|degrees?[ \t]*C|C\b))"#,
    #"(^|[^A-Za-z0-9_-])([A-Za-z0-9]*temperature|temp)[^A-Za-z0-9_:=.-]*(=|:)[ \t]*-?\d+(\.\d+)?([ \t]*(°C|celsius|degrees?[ \t]*C|C\b))?"#,
]
let numericObserved = numericTemperaturePatterns.contains { pattern in
    combinedOutput.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}
let helperOwned = geteuid() == 0
let durationSeconds = Int(finished.timeIntervalSince(started).rounded(.up))

let commandLine = "\(commandPath) \(commandArguments.joined(separator: " "))"
let sampleOutput = """
$ \(commandLine)
\(stdoutText)
--- stderr ---
\(stderrText)
"""

if let outputPath {
    write(sampleOutput, to: outputPath)
}

let status = """
command=\(commandLine)
providerSource=\(providerSource)
startedAt=\(ISO8601DateFormatter().string(from: started))
finishedAt=\(ISO8601DateFormatter().string(from: finished))
durationSeconds=\(durationSeconds)
timeoutSeconds=\(timeoutSeconds)
showInitialUsage=\(showInitialUsage)
powermetricsSamplers=\(powermetricsSamplers)
outputByteLimit=\(outputByteLimit)
stdoutBytes=\(stdoutByteCount)
stderrBytes=\(stderrByteCount)
stdoutTruncated=\(stdoutTruncated)
stderrTruncated=\(stderrTruncated)
timedOut=\(timedOut)
exitCode=\(exitCode)
helperOwned=\(helperOwned)
numericTemperatureObserved=\(numericObserved)
runError=\(runError.isEmpty ? "none" : runError)
"""

if let statusPath {
    write(status, to: statusPath)
}

let event = """
event=temperature-provider-sample
timestampUtc=\(isoNow())
pid=\(getpid())
uid=\(getuid())
euid=\(geteuid())
providerSource=\(providerSource)
providerCommandPath=\(commandPath)
powermetricsPath=\(powermetricsPath)
ioregPath=\(ioregPath)
sampleRateMs=\(sampleRateMs)
timeoutSeconds=\(timeoutSeconds)
showInitialUsage=\(showInitialUsage)
powermetricsSamplers=\(powermetricsSamplers)
outputByteLimit=\(outputByteLimit)
stdoutBytes=\(stdoutByteCount)
stderrBytes=\(stderrByteCount)
stdoutTruncated=\(stdoutTruncated)
stderrTruncated=\(stderrTruncated)
timedOut=\(timedOut)
exitCode=\(exitCode)
helperOwned=\(helperOwned)
numericTemperatureObserved=\(numericObserved)
effect=single-sample-proof-attempt

"""
append(event, to: logPath)
print(event, terminator: "")

if timedOut {
    exit(124)
}
exit(Int32(exitCode))
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
    local helper_path helper_log sample_output sample_status stdout_log stderr_log powermetrics_samplers provider_source show_initial_usage_arg
    helper_path="$(xml_escape "$MACOS_DIR/$HELPER_NAME")"
    helper_log="$(xml_escape "$RUNTIME_DIR/provider.log")"
    sample_output="$(xml_escape "$RUNTIME_DIR/numeric-temperature-output.txt")"
    sample_status="$(xml_escape "$RUNTIME_DIR/numeric-temperature-output.status")"
    stdout_log="$(xml_escape "$RUNTIME_DIR/provider.stdout.log")"
    stderr_log="$(xml_escape "$RUNTIME_DIR/provider.stderr.log")"
    powermetrics_samplers="$(xml_escape "$POWERMETRICS_SAMPLERS")"
    provider_source="$(xml_escape "$PROVIDER_SOURCE")"
    show_initial_usage_arg=""
    if [[ "$SHOW_INITIAL_USAGE" == true ]]; then
        show_initial_usage_arg="    <string>--show-initial-usage</string>"
    fi
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
    <string>--log</string>
    <string>$helper_log</string>
    <string>--sample-output</string>
    <string>$sample_output</string>
    <string>--sample-status</string>
    <string>$sample_status</string>
    <string>--provider-source</string>
    <string>$provider_source</string>
    <string>--timeout-seconds</string>
    <string>$TIMEOUT_SECONDS</string>
    <string>--sample-rate-ms</string>
    <string>$SAMPLE_RATE_MS</string>
    <string>--powermetrics-samplers</string>
    <string>$powermetrics_samplers</string>
$show_initial_usage_arg
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
if [[ "$REGISTER_EXISTING_ARTIFACT" == true ]]; then
    capture_register_status
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

capture_required "provider-command-or-api" plutil -p "$LAUNCHD_DIR/$PLIST_NAME"
capture_required "processinfo-supplemental-signal" swift -e 'import Foundation
let state = ProcessInfo.processInfo.thermalState
switch state {
case .nominal: print("thermalState=nominal")
case .fair: print("thermalState=fair")
case .serious: print("thermalState=serious")
case .critical: print("thermalState=critical")
@unknown default: print("thermalState=unknown")
}'
capture_optional "app-signing-before-sign" "$CODESIGN" -dvvv "$APP_DIR"
"$CODESIGN" --force --sign - "$MACOS_DIR/$APP_NAME" >/dev/null 2>"$EVIDENCE_DIR/controller-codesign.stderr"
"$CODESIGN" --force --sign - "$MACOS_DIR/$HELPER_NAME" >/dev/null 2>"$EVIDENCE_DIR/helper-codesign.stderr"
"$CODESIGN" --force --sign - --deep "$APP_DIR" >/dev/null 2>"$EVIDENCE_DIR/app-bundle-codesign.stderr"
capture_required "helper-ownership-model" "$CODESIGN" -dvvv "$MACOS_DIR/$HELPER_NAME"
capture_required "temperature-provider-status-before-approval" "$MACOS_DIR/$APP_NAME" status

MACOS_VERSION="$(sw_vers -productVersion)"
HARDWARE_ARCH="$(uname -m 2>/dev/null || echo unknown)"
CPU="Intel"
if [[ "$HARDWARE_ARCH" == arm64* ]]; then
    CPU="Apple Silicon"
fi
HARDWARE_CLASS="unknown"
if pmset -g batt 2>/dev/null | grep -Eiq 'InternalBattery|Battery Power|Now drawing from'; then
    HARDWARE_CLASS="MacBook"
else
    HARDWARE_CLASS="desktop"
fi
RESULT="inconclusive"

cat >"$EVIDENCE_DIR/no-user-visible-prompts.txt" <<EOF
noUserVisiblePrompts=true
This SMAppService proof harness never invokes promptable sudo. The helper is
expected to run as a launchd-managed daemon after explicit macOS approval.
EOF

cat >"$EVIDENCE_DIR/logs.txt" <<EOF
capturedAtUtc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
caseId=$CASE_ID
mode=prepare-or-register
providerSource=$PROVIDER_SOURCE
helperLabel=$HELPER_LABEL
identitySuffix=$IDENTITY_SUFFIX
registerAttempted=$REGISTER
showInitialUsage=$SHOW_INITIAL_USAGE
powermetricsSamplers=$POWERMETRICS_SAMPLERS
providerProofReady=false
EOF

cat >"$CONFIG_FILE" <<EOF
evidenceFormat=temperature-provider-proof-v1
metadataRedacted=true
macOSVersion=$MACOS_VERSION
cpu=$CPU
hardwareClass=$HARDWARE_CLASS
appBundleIdentifier=$BUNDLE_ID
providerSource=$PROVIDER_SOURCE
helperOwned=false
processInfoSupplementalOnly=true
numericCutoffSource=false
noUserVisiblePrompts=true
freshnessMaxAgeSeconds=$FRESHNESS_SECONDS
activeCadenceSeconds=$ACTIVE_CADENCE_SECONDS
idleCadenceSeconds=$IDLE_CADENCE_SECONDS
timeoutSeconds=$TIMEOUT_SECONDS
closedBagCoverage=insufficient
failClosedContract=unverified
result=$RESULT
caseId=$CASE_ID
helperInstallPath=smappservice
helperLabel=$HELPER_LABEL
identitySuffix=$IDENTITY_SUFFIX
sampleRateMs=$SAMPLE_RATE_MS
showInitialUsage=$SHOW_INITIAL_USAGE
powermetricsSamplers=$POWERMETRICS_SAMPLERS
registerAttempted=$REGISTER
unregisterAttempted=false
postApprovalCaptureAttempted=false
providerProofReady=false
EOF

cat >"$OUTPUT_DIR/manual-result.md" <<EOF
# Temperature Provider Proof Result

## Provider Case
- Case ID: $CASE_ID
- Provider source: $PROVIDER_SOURCE
- Powermetrics samplers: $POWERMETRICS_SAMPLERS
- Helper-owned provider: TODO - capture after SMAppService approval and at least a 15 second wait
- Numeric cutoff source: TODO - capture helper provider output, freshness, and cadence
- No user-visible prompts: yes
- ProcessInfo role: supplemental-only

## Sampling
- Freshest reading age seconds: TODO
- Active cadence seconds: TODO
- Idle cadence seconds: TODO
- Timeout seconds: $TIMEOUT_SECONDS

## Coverage
- Closed-bag coverage: insufficient
- Fail-closed cases recorded: TODO

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
    manifest_row "provider-command-or-api" "evidence" "evidence/provider-command-or-api.txt" "SMAppService LaunchDaemon provider command captured"
    manifest_row "helper-ownership-context" "TODO" "" "Capture root helper runtime context after approval"
    manifest_row "numeric-temperature-output" "TODO" "" "Capture helper provider output after approval"
    manifest_row "freshness-samples" "TODO" "" "Capture repeated helper/root samples and compute max age"
    manifest_row "active-cadence-samples" "TODO" "" "Capture samples at active cadence"
    manifest_row "idle-cadence-samples" "TODO" "" "Capture samples at idle cadence"
    manifest_row "timeout-enforcement" "TODO" "" "Capture helper-side timeout status after approval"
    manifest_row "timeout-fail-closed" "TODO" "" "Attach policy evidence that timeout blocks/releases Bag Mode"
    manifest_row "permission-behavior" "TODO" "" "Capture helper/root permission behavior after approval"
    manifest_row "no-user-visible-prompts" "evidence" "evidence/no-user-visible-prompts.txt" "SMAppService approval path; no promptable sudo"
    manifest_row "closed-bag-coverage-analysis" "TODO" "" "Analyze whether provider reading covers closed-bag risk"
    manifest_row "processinfo-supplemental-signal" "evidence" "evidence/processinfo-supplemental-signal.txt" "ProcessInfo thermalState captured as supplemental signal"
    manifest_row "safety-contract-tests" "TODO" "" "Attach mocked safety contract run for selected provider"
    manifest_row "unavailable-fail-closed" "TODO" "" "Attach unavailable provider fail-closed evidence"
    manifest_row "stale-fail-closed" "TODO" "" "Attach stale provider fail-closed evidence"
    manifest_row "permission-denied-fail-closed" "TODO" "" "Attach permission denied fail-closed evidence"
    manifest_row "parse-failed-fail-closed" "TODO" "" "Attach parse failure fail-closed evidence"
    manifest_row "helper-crashed-fail-closed" "TODO" "" "Attach helper crash fail-closed evidence"
    manifest_row "unsupported-hardware-fail-closed" "TODO" "" "Attach unsupported hardware fail-closed evidence"
    manifest_row "logs" "evidence" "evidence/logs.txt" "prepare/register summary log captured"
    manifest_row "combined-sensor-signal" "n/a" "" "closedBagCoverage=insufficient; combined signal evidence not selected"
    manifest_row "provider-update-or-restart" "n/a" "" "provider restart/update not exercised in this proof attempt"
} >"$MANIFEST_FILE"

OUTPUT_DIR_ARG="$(printf '%q' "$OUTPUT_DIR")"
README_INVOCATION="scripts/temperature-provider-smappservice-proof.sh --output-dir $OUTPUT_DIR_ARG"

cat >"$OUTPUT_DIR/README.md" <<EOF
# SMAppService Temperature Provider Proof Attempt

This artifact was produced by:

\`\`\`sh
$README_INVOCATION
\`\`\`

This package builds an ad-hoc signed SMAppService app/helper prototype for #25.
The default mode is non-mutating. It does not prove helper-owned thermal
sampling until \`--register --i-understand-this-registers-provider\` and
\`--capture-post-approval\` are run intentionally on the same artifact.

SMAppService identity:

- App bundle id: \`$BUNDLE_ID\`
- Helper label: \`$HELPER_LABEL\`
- Identity suffix: \`$IDENTITY_SUFFIX\`
- Provider source: \`$PROVIDER_SOURCE\`

Sampling:

- Powermetrics samplers: \`$POWERMETRICS_SAMPLERS\`
- Show initial usage: \`$SHOW_INITIAL_USAGE\`

Provider proof ready: \`false\`
Result: \`$RESULT\`

Run the structural verifier before attaching completed proof:

\`\`\`sh
scripts/temperature-provider-proof-verify.sh --manifest "$MANIFEST_FILE"
\`\`\`

Verifier failure is expected until TODO rows are replaced with real helper/root
freshness, cadence, closed-bag coverage, and fail-closed evidence.
EOF

echo "SMAppService temperature provider proof attempt written to $OUTPUT_DIR"
echo "Verifier is expected to fail until TODO rows are replaced with real evidence."
