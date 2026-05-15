#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/packaging-consent-audit.sh ..." >&2
    exit 2
fi
set -euo pipefail

OUTPUT_DIR=""
APP_BUNDLE=""
STAGE_APP=false
DEFAULT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="${AGENTWAKE_PACKAGING_AUDIT_ROOT_DIR:-$DEFAULT_ROOT_DIR}"

usage() {
    cat <<'EOF'
Usage: scripts/packaging-consent-audit.sh --output-dir DIR [--app-bundle APP] [--stage-app]

Audits the current packaged-app/release surface for silent privileged-helper
activation risks. This is a static, non-privileged check: it does not install a
package, register a helper, call SMAppService, or mutate launchd state.
EOF
}

strip_trailing_slashes() {
    local path="$1"
    while [[ "$path" != "/" && "$path" == */ ]]; do
        path="${path%/}"
    done
    printf '%s\n' "$path"
}

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

write_status() {
    local file="$1"
    local exit_code="$2"
    local command="$3"
    {
        printf 'command=%s\n' "$command"
        printf 'exitCode=%s\n' "$exit_code"
    } >"$file"
}

run_capture() {
    local output_file="$1"
    local status_file="$2"
    shift 2

    local temp_output exit_code command_string
    temp_output="$(mktemp "$EVIDENCE_DIR/.capture.XXXXXX")"
    exit_code=0
    command_string="$*"
    "$@" >"$temp_output" 2>&1 || exit_code=$?
    redact_metadata <"$temp_output" >"$output_file"
    rm -f "$temp_output"
    write_status "$status_file" "$exit_code" "$command_string"
    return 0
}

run_search_capture() {
    local output_file="$1"
    local status_file="$2"
    local pattern="$3"
    shift 3

    local temp_output exit_code command_string
    temp_output="$(mktemp "$EVIDENCE_DIR/.search.XXXXXX")"
    exit_code=0
    if command -v rg >/dev/null 2>&1; then
        command_string="rg -n $pattern $*"
        rg -n "$pattern" "$@" >"$temp_output" 2>&1 || exit_code=$?
    else
        command_string="grep -R -n -E $pattern $*"
        grep -R -n -E "$pattern" "$@" >"$temp_output" 2>&1 || exit_code=$?
    fi
    redact_metadata <"$temp_output" >"$output_file"
    rm -f "$temp_output"
    write_status "$status_file" "$exit_code" "$command_string"
}

run_search_file_list_capture() {
    local output_file="$1"
    local status_file="$2"
    local pattern="$3"
    local file_list="$4"

    local temp_output exit_code command_string
    temp_output="$(mktemp "$EVIDENCE_DIR/.search-list.XXXXXX")"
    exit_code=0
    if command -v rg >/dev/null 2>&1; then
        command_string="xargs rg -n $pattern"
        xargs rg -n "$pattern" <"$file_list" >"$temp_output" 2>&1 || exit_code=$?
    else
        command_string="xargs grep -n -E $pattern"
        xargs grep -n -E "$pattern" <"$file_list" >"$temp_output" 2>&1 || exit_code=$?
    fi
    redact_metadata <"$temp_output" >"$output_file"
    rm -f "$temp_output"
    write_status "$status_file" "$exit_code" "$command_string"
}

stage_app_bundle() {
    local target_bundle="$1"
    local target_contents="$target_bundle/Contents"
    local target_macos="$target_contents/MacOS"
    local build_dir

    swift build --package-path "$ROOT_DIR" --product AgentWake >/dev/null
    swift build --package-path "$ROOT_DIR" --product AgentWakeHookAdapter >/dev/null
    build_dir="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"

    rm -rf "$target_bundle"
    mkdir -p "$target_macos"
    cp "$build_dir/AgentWake" "$target_macos/AgentWake"
    cp "$build_dir/AgentWakeHookAdapter" "$target_macos/AgentWakeHookAdapter"
    chmod +x "$target_macos/AgentWake" "$target_macos/AgentWakeHookAdapter"

    cat >"$target_contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>AgentWake</string>
  <key>CFBundleIdentifier</key>
  <string>com.makeavish.AgentWake</string>
  <key>CFBundleName</key>
  <string>AgentWake</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

capture_release_automation_content() {
    local output_file="$1"
    local status_file="$2"
    local temp_output exit_code candidate_file candidate_list
    temp_output="$(mktemp "$EVIDENCE_DIR/.release-content.XXXXXX")"
    candidate_list="$(mktemp "$EVIDENCE_DIR/.release-content-files.XXXXXX")"
    exit_code=0

    {
        if [[ -d "$ROOT_DIR/.github" ]]; then
            find "$ROOT_DIR/.github" -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.sh' \)
        fi
        find "$ROOT_DIR" -maxdepth 1 -type f \( -name 'Makefile' -o -name '*.mk' -o -name '*.yml' -o -name '*.yaml' -o -name '*.rb' -o -name 'Brewfile' -o -name '*.sh' \)
        for candidate_file in "$ROOT_DIR"/script/* "$ROOT_DIR"/scripts/*; do
            [[ -f "$candidate_file" ]] || continue
            case "$(basename "$candidate_file")" in
                *release*|*package*|*pkg*|*cask*|*brew*|postinstall|postflight|preinstall|preflight)
                    printf '%s\n' "$candidate_file"
                    ;;
            esac
        done
    } | sort -u >"$candidate_list"

    if [[ -s "$candidate_list" ]]; then
        run_search_file_list_capture "$output_file" "$status_file" \
            "brew|cask|pkgbuild|productbuild|postinstall|postflight|preinstall|preflight|launchctl[[:space:]]+(bootstrap|bootout)|SMAppService|SMJobBless" \
            "$candidate_list"
    else
        : >"$temp_output"
        exit_code=1
        redact_metadata <"$temp_output" >"$output_file"
        write_status "$status_file" "$exit_code" "scan known release workflow/package/cask files for helper activation"
    fi

    redact_metadata <"$candidate_list" >"$EVIDENCE_DIR/release-automation-content-files.txt"
    rm -f "$temp_output" "$candidate_list"
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
        --app-bundle)
            if [[ "$#" -lt 2 ]]; then
                echo "--app-bundle requires a value" >&2
                exit 2
            fi
            APP_BUNDLE="$2"
            shift 2
            ;;
        --stage-app)
            STAGE_APP=true
            shift
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

if [[ "$STAGE_APP" == true && -n "$APP_BUNDLE" ]]; then
    echo "Use either --stage-app or --app-bundle, not both." >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR/evidence"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
EVIDENCE_DIR="$OUTPUT_DIR/evidence"

if [[ "$STAGE_APP" == true ]]; then
    APP_BUNDLE="$OUTPUT_DIR/staged/AgentWake.app"
    stage_app_bundle "$APP_BUNDLE"
elif [[ -z "$APP_BUNDLE" ]]; then
    APP_BUNDLE="$ROOT_DIR/dist/AgentWake.app"
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "App bundle is not a directory: $APP_BUNDLE" >&2
    exit 2
fi

APP_BUNDLE="$(cd "$APP_BUNDLE" && pwd)"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_CONTENTS="$APP_BUNDLE/Contents"

if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Info.plist is missing: $INFO_PLIST" >&2
    exit 2
fi

run_capture "$EVIDENCE_DIR/app-bundle-layout.txt" "$EVIDENCE_DIR/app-bundle-layout.status" \
    find "$APP_CONTENTS" -maxdepth 4 -print
run_capture "$EVIDENCE_DIR/info-plist.txt" "$EVIDENCE_DIR/info-plist.status" \
    plutil -p "$INFO_PLIST"
run_search_capture "$EVIDENCE_DIR/production-activation-source-scan.txt" "$EVIDENCE_DIR/production-activation-source-scan.status" \
    "SMAppService|SMJobBless|AuthorizationExecuteWithPrivileges|/Library/LaunchDaemons|launchctl[[:space:]]+(bootstrap|bootout)|register\\(" \
    "$ROOT_DIR/Sources" "$ROOT_DIR/script" "$ROOT_DIR/Package.swift"
run_capture "$EVIDENCE_DIR/release-automation-scan.txt" "$EVIDENCE_DIR/release-automation-scan.status" \
    find "$ROOT_DIR" -maxdepth 3 \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.build" -o -path "$ROOT_DIR/dist" \) -prune -o \( -iname '*cask*' -o -iname 'Casks' -o -iname '*.rb' -o -iname '*.pkg' -o -iname 'postinstall' -o -iname 'postflight' -o -iname 'preinstall' -o -iname 'preflight' \) -print
capture_release_automation_content "$EVIDENCE_DIR/release-automation-content-scan.txt" "$EVIDENCE_DIR/release-automation-content-scan.status"

launchdaemon_count=0
if [[ -d "$APP_CONTENTS/Library/LaunchDaemons" ]]; then
    launchdaemon_count="$(find "$APP_CONTENTS/Library/LaunchDaemons" -type f -name '*.plist' | wc -l | tr -d ' ')"
fi
info_plist_parseable=false
if grep -q '^exitCode=0$' "$EVIDENCE_DIR/info-plist.status"; then
    info_plist_parseable=true
fi
sm_privileged_present=false
if [[ "$info_plist_parseable" == true ]] &&
   /usr/libexec/PlistBuddy -c 'Print :SMPrivilegedExecutables' "$INFO_PLIST" >/dev/null 2>&1; then
    sm_privileged_present=true
fi

source_scan_matches=false
if [[ -s "$EVIDENCE_DIR/production-activation-source-scan.txt" ]]; then
    source_scan_matches=true
fi

release_artifact_matches=false
if [[ -s "$EVIDENCE_DIR/release-automation-scan.txt" ]]; then
    release_artifact_matches=true
fi
release_content_matches=false
if [[ -s "$EVIDENCE_DIR/release-automation-content-scan.txt" ]]; then
    release_content_matches=true
fi

silent_activation_risk=false
if [[ "$launchdaemon_count" != "0" ||
      "$info_plist_parseable" != true ||
      "$sm_privileged_present" == true ||
      "$source_scan_matches" == true ||
      "$release_artifact_matches" == true ||
      "$release_content_matches" == true ]]; then
    silent_activation_risk=true
fi

result="pass"
if [[ "$silent_activation_risk" == true ]]; then
    result="needs-review"
fi

cat >"$EVIDENCE_DIR/helper-activation-summary.txt" <<EOF
appBundle=$APP_BUNDLE
infoPlist=$INFO_PLIST
launchDaemonPlistCount=$launchdaemon_count
infoPlistParseable=$info_plist_parseable
smPrivilegedExecutablesPresent=$sm_privileged_present
productionActivationSourceMatches=$source_scan_matches
releaseAutomationArtifactMatches=$release_artifact_matches
releaseAutomationContentMatches=$release_content_matches
silentActivationRisk=$silent_activation_risk
result=$result
EOF
redact_metadata <"$EVIDENCE_DIR/helper-activation-summary.txt" >"$EVIDENCE_DIR/helper-activation-summary.redacted"
mv "$EVIDENCE_DIR/helper-activation-summary.redacted" "$EVIDENCE_DIR/helper-activation-summary.txt"

cat >"$OUTPUT_DIR/validation-config.txt" <<EOF
evidenceFormat=packaging-consent-audit-v1
metadataRedacted=true
appBundle=$APP_BUNDLE
launchDaemonPlistCount=$launchdaemon_count
infoPlistParseable=$info_plist_parseable
smPrivilegedExecutablesPresent=$sm_privileged_present
productionActivationSourceMatches=$source_scan_matches
releaseAutomationArtifactMatches=$release_artifact_matches
releaseAutomationContentMatches=$release_content_matches
silentActivationRisk=$silent_activation_risk
result=$result
EOF
redact_metadata <"$OUTPUT_DIR/validation-config.txt" >"$OUTPUT_DIR/validation-config.redacted"
mv "$OUTPUT_DIR/validation-config.redacted" "$OUTPUT_DIR/validation-config.txt"

cat >"$OUTPUT_DIR/README.md" <<EOF
# Packaging Consent Audit

This package captures a static audit for the current packaged-app/release
surface. It checks that the staged app and repository release automation do not
contain a production path that can silently activate a privileged helper before
user consent.

Evidence files:

- \`evidence/app-bundle-layout.txt\`
- \`evidence/info-plist.txt\`
- \`evidence/production-activation-source-scan.txt\`
- \`evidence/release-automation-scan.txt\`
- \`evidence/release-automation-content-files.txt\`
- \`evidence/release-automation-content-scan.txt\`
- \`evidence/helper-activation-summary.txt\`

Boundary: this does not install a Homebrew cask or package. It proves the
current audited app bundle and known release workflow/package/cask files have
no detected install-time or launch-time privileged helper activation path. If
future builds include helper LaunchDaemon assets, cask files, package scripts,
or new release automation paths, rerun this audit and attach real cask/package
install evidence before promoting the #120 packaging row.
EOF

echo "Packaging consent audit written to $OUTPUT_DIR"
if [[ "$result" != "pass" ]]; then
    echo "Packaging consent audit needs review; inspect $EVIDENCE_DIR/helper-activation-summary.txt" >&2
    exit 1
fi
