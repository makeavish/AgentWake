#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/helper-service-readiness.sh --output-dir DIR
   or: scripts/helper-service-readiness.sh DIR

Captures non-mutating local readiness evidence for the SMAppService helper
prototype. This script does not register, unregister, install, approve, or run a
LaunchDaemon. It only records whether the current machine has the signing and
tooling prerequisites for the signed prototype.
USAGE
}

OUTPUT_DIR=""
RAW_IDENTITY_FILES=()

cleanup() {
    if [[ "${#RAW_IDENTITY_FILES[@]}" -gt 0 ]]; then
        rm -f "${RAW_IDENTITY_FILES[@]}"
    fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            if [[ $# -lt 2 ]]; then
                echo "--output-dir requires a value" >&2
                exit 64
            fi
            OUTPUT_DIR=$2
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
            OUTPUT_DIR=$1
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

CAPTURE_TIMEOUT_SECONDS=${CLAWSHELL_HELPER_READINESS_TIMEOUT_SECONDS:-5}
if ! [[ "$CAPTURE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$CAPTURE_TIMEOUT_SECONDS" -le 0 ]]; then
    echo "CLAWSHELL_HELPER_READINESS_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 64
fi

if [[ -e "$OUTPUT_DIR" ]]; then
    if [[ -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
        echo "Output directory is not empty: $OUTPUT_DIR" >&2
        exit 73
    fi
fi

mkdir -p "$OUTPUT_DIR"

capture() {
    local name=$1
    shift
    capture_to "$OUTPUT_DIR/${name}.txt" "$OUTPUT_DIR/${name}.status" "$@"
}

capture_to() {
    local out_file=$1
    local status_file=$2
    shift 2
    local start
    local finish
    local pid
    local status=0
    local timed_out=false
    local cmd=("$@")

    start=$(date +%s)
    set +m
    (
        child_pid=""
        trap 'if [[ -n "$child_pid" ]]; then kill "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; fi; exit 124' TERM
        "${cmd[@]}" &
        child_pid=$!
        wait "$child_pid"
    ) >"$out_file" 2>&1 &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        local now
        now=$(date +%s)
        if (( now - start >= CAPTURE_TIMEOUT_SECONDS )); then
            timed_out=true
            kill "$pid" 2>/dev/null || true
            sleep 0.1
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
            break
        fi
        sleep 0.05
    done

    set +e
    wait "$pid" 2>/dev/null
    status=$?
    set -e
    finish=$(date +%s)

    {
        printf "command="
        printf "%q" "${cmd[0]}"
        for part in "${cmd[@]:1}"; do
            printf " %q" "$part"
        done
        printf "\n"
        echo "durationSeconds=$(( finish - start ))"
        echo "timeoutSeconds=$CAPTURE_TIMEOUT_SECONDS"
        echo "timedOut=$timed_out"
        echo "exitCode=$status"
    } >"$status_file"
    return 0
}

status_value() {
    local name=$1
    local key=$2
    sed -n "s/^${key}=//p" "$OUTPUT_DIR/${name}.status" | head -n 1
}

redact_identities() {
    local policy=$1
    local raw_file=$2
    local output_file=$3
    awk '
        /Developer ID Application:/ { developer_id_application += 1; next }
        /Developer ID Installer:/ { developer_id_installer += 1; next }
        /Apple Development:/ { apple_development += 1; next }
        /Apple Distribution:/ { apple_distribution += 1; next }
        /valid identities found/ { total = $1; next }
        END {
            if (total == "") {
                total = developer_id_application + developer_id_installer + apple_development + apple_distribution
            }
            print "validCodeSigningIdentityCount=" total
            print "developerIDApplicationIdentityCount=" developer_id_application + 0
            print "developerIDInstallerIdentityCount=" developer_id_installer + 0
            print "appleDevelopmentIdentityCount=" apple_development + 0
            print "appleDistributionIdentityCount=" apple_distribution + 0
        }
    ' "$raw_file" >"$output_file"
    {
        echo "policy=$policy"
        cat "$output_file"
    } >"${output_file}.tmp"
    mv "${output_file}.tmp" "$output_file"
}

codesigning_raw="$(mktemp)"
installer_raw="$(mktemp)"
RAW_IDENTITY_FILES+=("$codesigning_raw" "$installer_raw")
capture_to "$codesigning_raw" "$OUTPUT_DIR/codesigning-identities.status" security find-identity -p codesigning -v
redact_identities "codesigning" "$codesigning_raw" "$OUTPUT_DIR/codesigning-identities.txt"
capture_to "$installer_raw" "$OUTPUT_DIR/installer-identities.status" security find-identity -p basic -v
redact_identities "basic" "$installer_raw" "$OUTPUT_DIR/installer-identities.txt"
capture "xcodebuild-version" xcodebuild -version
capture "swift-version" swift --version
capture "pkgbuild-path" command -v pkgbuild
capture "productbuild-path" command -v productbuild
capture "xcode-select-path" xcode-select -p
capture "macos-sdk-path" xcrun --sdk macosx --show-sdk-path
capture "codesign-path" xcrun --find codesign
capture "notarytool-path" xcrun --find notarytool

codesigning_count="$(sed -n 's/^validCodeSigningIdentityCount=//p' "$OUTPUT_DIR/codesigning-identities.txt")"
[[ -n "$codesigning_count" ]] || codesigning_count=0
developer_id_application_count="$(sed -n 's/^developerIDApplicationIdentityCount=//p' "$OUTPUT_DIR/codesigning-identities.txt")"
developer_id_installer_count="$(sed -n 's/^developerIDInstallerIdentityCount=//p' "$OUTPUT_DIR/installer-identities.txt")"
apple_development_count="$(sed -n 's/^appleDevelopmentIdentityCount=//p' "$OUTPUT_DIR/codesigning-identities.txt")"
apple_distribution_count="$(sed -n 's/^appleDistributionIdentityCount=//p' "$OUTPUT_DIR/codesigning-identities.txt")"

xcodebuild_available=false
if grep -q '^exitCode=0$' "$OUTPUT_DIR/xcodebuild-version.status"; then
    xcodebuild_available=true
fi

pkgbuild_available=false
if grep -q '^exitCode=0$' "$OUTPUT_DIR/pkgbuild-path.status"; then
    pkgbuild_available=true
fi

productbuild_available=false
if grep -q '^exitCode=0$' "$OUTPUT_DIR/productbuild-path.status"; then
    productbuild_available=true
fi

macos_sdk_available=false
if grep -q '^exitCode=0$' "$OUTPUT_DIR/macos-sdk-path.status"; then
    macos_sdk_available=true
fi

codesign_available=false
if grep -q '^exitCode=0$' "$OUTPUT_DIR/codesign-path.status"; then
    codesign_available=true
fi

notarytool_available=false
if grep -q '^exitCode=0$' "$OUTPUT_DIR/notarytool-path.status"; then
    notarytool_available=true
fi

prototype_ready=false
if [[ "$developer_id_application_count" -gt 0 &&
      "$developer_id_installer_count" -gt 0 &&
      "$xcodebuild_available" == true &&
      "$pkgbuild_available" == true &&
      "$productbuild_available" == true &&
      "$macos_sdk_available" == true &&
      "$codesign_available" == true ]]; then
    prototype_ready=true
fi

{
    echo "capturedAtUtc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "timeoutSeconds=$CAPTURE_TIMEOUT_SECONDS"
    echo "validCodeSigningIdentityCount=$codesigning_count"
    echo "developerIDApplicationIdentityCount=$developer_id_application_count"
    echo "developerIDInstallerIdentityCount=$developer_id_installer_count"
    echo "appleDevelopmentIdentityCount=$apple_development_count"
    echo "appleDistributionIdentityCount=$apple_distribution_count"
    echo "xcodebuildAvailable=$xcodebuild_available"
    echo "pkgbuildAvailable=$pkgbuild_available"
    echo "productbuildAvailable=$productbuild_available"
    echo "macosSdkAvailable=$macos_sdk_available"
    echo "codesignAvailable=$codesign_available"
    echo "notarytoolAvailable=$notarytool_available"
    echo "signedPrototypeReady=$prototype_ready"
    echo "metadataRedacted=true"
} >"$OUTPUT_DIR/validation-config.txt"

cat >"$OUTPUT_DIR/summary.md" <<EOF
# Helper Service Readiness Result

Captured at: $(date -u +%Y-%m-%dT%H:%M:%SZ)

This artifact is non-mutating. It did not install, register, approve, unregister,
or run any helper.

## Result

- Valid code-signing identities: \`$codesigning_count\`
- Developer ID Application identities: \`$developer_id_application_count\`
- Developer ID Installer identities: \`$developer_id_installer_count\`
- xcodebuild available: \`$xcodebuild_available\`
- pkgbuild available: \`$pkgbuild_available\`
- productbuild available: \`$productbuild_available\`
- macOS SDK available through xcrun: \`$macos_sdk_available\`
- codesign available through xcrun: \`$codesign_available\`
- notarytool available through xcrun: \`$notarytool_available\`
- Signed prototype ready in this environment: \`$prototype_ready\`

## Conclusion

The signed SMAppService helper prototype is not complete unless
\`signedPrototypeReady=true\` and a separate prototype run records register,
approval, update, uninstall, and failure-case evidence.
EOF

echo "Helper service readiness written to $OUTPUT_DIR"
