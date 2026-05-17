#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR=""
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AgentWake"
HOOK_ADAPTER_NAME="AgentWakeHookAdapter"
BUNDLE_ID="com.makeavish.AgentWake"
MIN_SYSTEM_VERSION="13.0"
SHORT_VERSION="0.0.0"
BUILD_VERSION="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || date -u +%Y%m%d%H%M)"
APP_ICON_SOURCE="$ROOT_DIR/Resources/AgentWake.icns"
APP_ICON_NAME="AgentWake"

usage() {
    cat <<'EOF'
Usage: scripts/app-clean-install-smoke.sh --output-dir DIR

Builds an isolated AgentWake app bundle, copies it into a clean install root
under the evidence directory, launches that copied app, and captures CLI and
Accessibility evidence for the exact installed-copy process.

This is a live local smoke: it opens AgentWake and may require Accessibility
permission for System Events.
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

capture_command() {
    local name="$1"
    shift

    local temp_output exit_code
    temp_output="$(mktemp "$EVIDENCE_DIR/.$name.XXXXXX")"
    if "$@" >"$temp_output" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi
    redact_metadata <"$temp_output" >"$EVIDENCE_DIR/$name.txt"
    rm -f "$temp_output"
    printf 'exitCode=%s\n' "$exit_code" >"$EVIDENCE_DIR/$name.status"
    return "$exit_code"
}

stage_source_app_bundle() {
    local temp_output exit_code build_dir

    temp_output="$(mktemp "$EVIDENCE_DIR/.stage-source-app.XXXXXX")"
    exit_code=0
    {
        swift build --package-path "$ROOT_DIR" --product "$APP_NAME" &&
        swift build --package-path "$ROOT_DIR" --product "$HOOK_ADAPTER_NAME" &&
        build_dir="$(swift build --package-path "$ROOT_DIR" --show-bin-path)" &&
        rm -rf "$SOURCE_APP_BUNDLE" &&
        mkdir -p "$SOURCE_APP_MACOS" "$SOURCE_APP_RESOURCES" &&
        cp "$build_dir/$APP_NAME" "$SOURCE_APP_BINARY" &&
        cp "$build_dir/$HOOK_ADAPTER_NAME" "$SOURCE_HOOK_ADAPTER_BINARY" &&
        cp "$APP_ICON_SOURCE" "$SOURCE_APP_RESOURCES/$APP_ICON_NAME.icns" &&
        chmod +x "$SOURCE_APP_BINARY" "$SOURCE_HOOK_ADAPTER_BINARY" &&
        cat >"$SOURCE_INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Vishal Sharma. All rights reserved.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
    } >"$temp_output" 2>&1 || exit_code=$?

    redact_metadata <"$temp_output" >"$EVIDENCE_DIR/stage-source-app.txt"
    rm -f "$temp_output"
    printf 'exitCode=%s\n' "$exit_code" >"$EVIDENCE_DIR/stage-source-app.status"
    return "$exit_code"
}

copy_into_clean_install_root() {
    rm -rf "$INSTALL_ROOT"
    mkdir -p "$INSTALL_APPLICATIONS_DIR"
    /usr/bin/ditto "$SOURCE_APP_BUNDLE" "$INSTALLED_APP_BUNDLE"
    [[ -x "$INSTALLED_APP_BINARY" ]]
    [[ -x "$INSTALLED_HOOK_ADAPTER_BINARY" ]]
}

all_agentwake_pids() {
    pgrep -x "$APP_NAME" || true
}

installed_pids() {
    local candidate_pid candidate_command
    while read -r candidate_pid; do
        [[ -n "$candidate_pid" ]] || continue
        candidate_command="$(ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
        case "$candidate_command" in
            "$INSTALLED_APP_BINARY"*)
                printf '%s\n' "$candidate_pid"
                ;;
        esac
    done < <(all_agentwake_pids)
}

other_agentwake_pids() {
    local candidate_pid candidate_command
    while read -r candidate_pid; do
        [[ -n "$candidate_pid" ]] || continue
        candidate_command="$(ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
        case "$candidate_command" in
            "$INSTALLED_APP_BINARY"*)
                ;;
            *)
                printf '%s\n' "$candidate_pid"
                ;;
        esac
    done < <(all_agentwake_pids)
}

stop_installed_copy() {
    local candidate_pid
    for candidate_pid in $(installed_pids); do
        kill "$candidate_pid" >/dev/null 2>&1 || true
    done
    if wait_for_installed_process_count 0; then
        return 0
    fi
    for candidate_pid in $(installed_pids); do
        kill -KILL "$candidate_pid" >/dev/null 2>&1 || true
    done
    wait_for_installed_process_count 0
}

cleanup() {
    if [[ "${CLEANUP_READY:-false}" == "true" ]]; then
        stop_installed_copy >/dev/null 2>&1 || true
    fi
}

wait_for_installed_process_count() {
    local expected_count="$1"
    local count
    for _ in $(seq 1 100); do
        count="$(installed_pids | sed '/^$/d' | wc -l | tr -d ' ')"
        if [[ "$count" == "$expected_count" ]]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

capture_process_snapshot() {
    local name="$1"
    local installed_pid installed_count
    installed_count=0
    {
        printf 'sourceAppBundle=%s\n' "$SOURCE_APP_BUNDLE"
        printf 'installedAppBundle=%s\n' "$INSTALLED_APP_BUNDLE"
        printf 'installedAppBinary=%s\n' "$INSTALLED_APP_BINARY"
        printf 'installedPIDs='
        installed_pids | paste -sd ',' -
        printf '\n'
        while read -r installed_pid; do
            [[ -n "$installed_pid" ]] || continue
            installed_count=$((installed_count + 1))
            printf 'installedProcessCommand[%s]=%s\n' "$installed_pid" "$(ps -p "$installed_pid" -o command= 2>/dev/null || true)"
        done < <(installed_pids)
        printf 'matchingInstalledProcessCount=%s\n' "$installed_count"
        printf 'otherAgentWakePIDs='
        other_agentwake_pids | paste -sd ',' -
        printf '\n'
    } | redact_metadata >"$EVIDENCE_DIR/$name.txt"
}

single_installed_pid() {
    local pids count
    pids="$(installed_pids)"
    count="$(printf '%s\n' "$pids" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$count" != "1" ]]; then
        return 1
    fi
    printf '%s\n' "$pids"
}

require_no_other_agentwake_processes() {
    local other count
    other="$(other_agentwake_pids)"
    count="$(printf '%s\n' "$other" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$count" != "0" ]]; then
        capture_process_snapshot "unexpected-other-processes"
        echo "Expected no other AgentWake processes before clean-install launch; inspect $EVIDENCE_DIR/unexpected-other-processes.txt" >&2
        return 1
    fi
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
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
EVIDENCE_DIR="$OUTPUT_DIR/evidence"
SOURCE_APP_BUNDLE="$OUTPUT_DIR/staged/AgentWake.app"
SOURCE_APP_CONTENTS="$SOURCE_APP_BUNDLE/Contents"
SOURCE_APP_MACOS="$SOURCE_APP_CONTENTS/MacOS"
SOURCE_APP_RESOURCES="$SOURCE_APP_CONTENTS/Resources"
SOURCE_APP_BINARY="$SOURCE_APP_MACOS/$APP_NAME"
SOURCE_HOOK_ADAPTER_BINARY="$SOURCE_APP_MACOS/$HOOK_ADAPTER_NAME"
SOURCE_INFO_PLIST="$SOURCE_APP_CONTENTS/Info.plist"
INSTALL_ROOT="$OUTPUT_DIR/install-root"
INSTALL_APPLICATIONS_DIR="$INSTALL_ROOT/Applications"
INSTALLED_APP_BUNDLE="$INSTALL_APPLICATIONS_DIR/AgentWake.app"
INSTALLED_APP_BINARY="$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME"
INSTALLED_HOOK_ADAPTER_BINARY="$INSTALLED_APP_BUNDLE/Contents/MacOS/$HOOK_ADAPTER_NAME"
CLEANUP_READY=true
trap cleanup EXIT

if ! stage_source_app_bundle; then
    echo "Clean-install source app staging failed; inspect $EVIDENCE_DIR/stage-source-app.txt" >&2
    exit 1
fi
copy_output="$(mktemp "$EVIDENCE_DIR/.copy-into-install-root.XXXXXX")"
if copy_into_clean_install_root >"$copy_output" 2>&1; then
    copy_exit=0
else
    copy_exit=$?
fi
redact_metadata <"$copy_output" >"$EVIDENCE_DIR/copy-into-install-root.txt"
rm -f "$copy_output"
printf 'exitCode=%s\n' "$copy_exit" >"$EVIDENCE_DIR/copy-into-install-root.status"
if [[ "$copy_exit" != "0" ]]; then
    echo "Copy into clean install root failed; inspect $EVIDENCE_DIR/copy-into-install-root.txt" >&2
    exit 1
fi

stop_installed_copy
require_no_other_agentwake_processes
capture_process_snapshot "before-launch-processes"

if ! capture_command "open-installed-copy" /bin/bash -c 'AGENTWAKE_SKIP_ONBOARDING=1 "$1" >/dev/null 2>&1 &' _ "$INSTALLED_APP_BINARY"; then
    echo "Clean installed app launch failed; inspect $EVIDENCE_DIR/open-installed-copy.txt" >&2
    exit 1
fi
if ! wait_for_installed_process_count 1; then
    capture_process_snapshot "after-launch-processes"
    echo "Timed out waiting for one clean-installed AgentWake process" >&2
    exit 1
fi
if ! single_installed_pid >"$EVIDENCE_DIR/installed-app.pid"; then
    capture_process_snapshot "after-launch-processes"
    echo "Expected exactly one clean-installed AgentWake process" >&2
    exit 1
fi
expected_pid="$(cat "$EVIDENCE_DIR/installed-app.pid")"
capture_process_snapshot "after-launch-processes"
require_no_other_agentwake_processes

if ! capture_command "cli-status" swift run --package-path "$ROOT_DIR" AgentWakeCLI status; then
    echo "AgentWake CLI status failed for clean-installed copy; inspect $EVIDENCE_DIR/cli-status.txt" >&2
    exit 1
fi

ui_output="$(mktemp "$EVIDENCE_DIR/.accessibility.XXXXXX")"
if AGENTWAKE_EXPECTED_PID="$expected_pid" osascript >"$ui_output" 2>&1 <<'APPLESCRIPT'
set outputLines to {}
set expectedPID to system attribute "AGENTWAKE_EXPECTED_PID"
tell application "System Events"
    set targetProcess to missing value
    repeat with candidateProcess in (processes whose name is "AgentWake")
        if ((unix id of candidateProcess) as text) is expectedPID then
            set targetProcess to candidateProcess
            exit repeat
        end if
    end repeat

    if targetProcess is missing value then
        set outputLines to outputLines & {"processExists=false"}
    else
        tell targetProcess
            set outputLines to outputLines & {"processExists=true"}
            set outputLines to outputLines & {"unixID=" & ((unix id) as text)}
            set outputLines to outputLines & {"backgroundOnly=" & ((background only) as text)}
            set outputLines to outputLines & {"visible=" & (visible as text)}
            set outputLines to outputLines & {"menuBarCount=" & ((count of menu bars) as text)}
            set statusItemFound to false
            repeat with menuBarRef in menu bars
                repeat with itemRef in menu bar items of menuBarRef
                    set itemName to ""
                    set itemDescription to ""
                    try
                        set itemName to name of itemRef as text
                    end try
                    try
                        set itemDescription to description of itemRef as text
                    end try
                    if itemName is "AgentWake" then
                        set statusItemFound to true
                        set outputLines to outputLines & {"statusItemName=" & itemName}
                        set outputLines to outputLines & {"statusItemDescription=" & itemDescription}
                    end if
                end repeat
            end repeat
            set outputLines to outputLines & {"statusItemFound=" & (statusItemFound as text)}
        end tell
    end if
end tell
set AppleScript's text item delimiters to linefeed
return outputLines as text
APPLESCRIPT
then
    ui_exit=0
else
    ui_exit=$?
fi
redact_metadata <"$ui_output" >"$EVIDENCE_DIR/accessibility-menu-bar.txt"
rm -f "$ui_output"
printf 'exitCode=%s\n' "$ui_exit" >"$EVIDENCE_DIR/accessibility-menu-bar.status"
if [[ "$ui_exit" != "0" ]]; then
    echo "AgentWake Accessibility capture failed for clean-installed copy; inspect $EVIDENCE_DIR/accessibility-menu-bar.txt" >&2
    exit 1
fi

cli_reachable=false
if grep -q '^AgentWake ' "$EVIDENCE_DIR/cli-status.txt"; then
    cli_reachable=true
fi

status_item_found=false
if grep -q '^statusItemFound=true$' "$EVIDENCE_DIR/accessibility-menu-bar.txt" &&
   grep -q "^unixID=$expected_pid$" "$EVIDENCE_DIR/accessibility-menu-bar.txt" &&
   grep -q '^statusItemName=AgentWake$' "$EVIDENCE_DIR/accessibility-menu-bar.txt" &&
   grep -q '^statusItemDescription=AgentWake status:' "$EVIDENCE_DIR/accessibility-menu-bar.txt"; then
    status_item_found=true
fi

installed_copy_launched=false
if grep -q "installedPIDs=$expected_pid" "$EVIDENCE_DIR/after-launch-processes.txt" &&
   grep -q '^matchingInstalledProcessCount=1$' "$EVIDENCE_DIR/after-launch-processes.txt"; then
    installed_copy_launched=true
fi

other_process_count="$(other_agentwake_pids | sed '/^$/d' | wc -l | tr -d ' ')"
matching_installed_process_count="$(installed_pids | sed '/^$/d' | wc -l | tr -d ' ')"
cleanup_succeeded=false
if stop_installed_copy; then
    cleanup_succeeded=true
    CLEANUP_READY=false
fi
printf 'cleanupSucceeded=%s\n' "$cleanup_succeeded" >"$EVIDENCE_DIR/cleanup-installed-copy.status"
capture_process_snapshot "after-cleanup-processes"

result="pass"
if [[ "$installed_copy_launched" != true ||
      "$matching_installed_process_count" != "1" ||
      "$other_process_count" != "0" ||
      "$cli_reachable" != true ||
      "$status_item_found" != true ||
      "$cleanup_succeeded" != true ]]; then
    result="fail"
fi

cat >"$OUTPUT_DIR/validation-config.txt" <<EOF
evidenceFormat=app-clean-install-smoke-v1
metadataRedacted=true
sourceAppBundle=$SOURCE_APP_BUNDLE
installedAppBundle=$INSTALLED_APP_BUNDLE
installedAppPID=$expected_pid
launchFromCleanInstallCopy=$installed_copy_launched
matchingInstalledProcessCount=$matching_installed_process_count
otherAgentWakeProcessCount=$other_process_count
cliReachable=$cli_reachable
accessibilityStatusItemFound=$status_item_found
cleanupSucceeded=$cleanup_succeeded
result=$result
EOF
redact_metadata <"$OUTPUT_DIR/validation-config.txt" >"$OUTPUT_DIR/validation-config.redacted"
mv "$OUTPUT_DIR/validation-config.redacted" "$OUTPUT_DIR/validation-config.txt"

cat >"$OUTPUT_DIR/README.md" <<'EOF'
# App Clean Install Smoke

This package captures live local evidence that AgentWake can be built as an
isolated app bundle, copied into a clean install root under this evidence
directory, launched from that copied location, reached by the CLI, and observed
as an AgentWake menu bar item through macOS Accessibility.

Evidence files:

- `evidence/stage-source-app.txt`
- `evidence/copy-into-install-root.txt`
- `evidence/before-launch-processes.txt`
- `evidence/open-installed-copy.txt`
- `evidence/after-launch-processes.txt`
- `evidence/cli-status.txt`
- `evidence/accessibility-menu-bar.txt`
- `evidence/cleanup-installed-copy.status`
- `evidence/after-cleanup-processes.txt`

This smoke supports the packaged-app clean-install row with an isolated local
install copy. It is not a Homebrew cask, package installer, upgrade, uninstall,
Gatekeeper, notarization, or helper-registration lifecycle proof.
EOF

if [[ "$result" != "pass" ]]; then
    echo "AgentWake clean-install app smoke failed; inspect $OUTPUT_DIR" >&2
    exit 1
fi

echo "App clean-install smoke written to $OUTPUT_DIR"
