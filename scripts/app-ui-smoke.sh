#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR=""
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: scripts/app-ui-smoke.sh --output-dir DIR

Builds and launches the staged AgentWake app bundle, then captures local
accessibility evidence for the menu bar item and Settings flow. This is a live
UI smoke: it opens AgentWake and may require Accessibility permission for System
Events.
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
APP_BINARY="$ROOT_DIR/dist/AgentWake.app/Contents/MacOS/AgentWake"

build_output="$(mktemp "$EVIDENCE_DIR/.build.XXXXXX")"
if "$ROOT_DIR/script/build_and_run.sh" --verify >"$build_output" 2>&1; then
    build_exit=0
else
    build_exit=$?
fi
redact_metadata <"$build_output" >"$EVIDENCE_DIR/build-and-run.txt"
rm -f "$build_output"
printf 'exitCode=%s\n' "$build_exit" >"$EVIDENCE_DIR/build-and-run.status"
if [[ "$build_exit" != "0" ]]; then
    echo "AgentWake app bundle launch verification failed; inspect $EVIDENCE_DIR/build-and-run.txt" >&2
    exit 1
fi

expected_pid=""
matching_count=0
while read -r candidate_pid; do
    [[ -n "$candidate_pid" ]] || continue
    candidate_command="$(ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
    case "$candidate_command" in
        "$APP_BINARY"*)
            expected_pid="$candidate_pid"
            matching_count=$((matching_count + 1))
            ;;
    esac
done < <(pgrep -x AgentWake || true)

{
    printf 'appBinary=%s\n' "$APP_BINARY"
    printf 'matchingStagedProcessCount=%s\n' "$matching_count"
    printf 'expectedPID=%s\n' "$expected_pid"
} | redact_metadata >"$EVIDENCE_DIR/staged-process.txt"

if [[ "$matching_count" != "1" || -z "$expected_pid" ]]; then
    echo "Expected exactly one staged AgentWake process; inspect $EVIDENCE_DIR/staged-process.txt" >&2
    exit 1
fi

cli_output="$(mktemp "$EVIDENCE_DIR/.cli.XXXXXX")"
if swift run --package-path "$ROOT_DIR" AgentWakeCLI status >"$cli_output" 2>&1; then
    cli_exit=0
else
    cli_exit=$?
fi
redact_metadata <"$cli_output" >"$EVIDENCE_DIR/cli-status.txt"
rm -f "$cli_output"
printf 'exitCode=%s\n' "$cli_exit" >"$EVIDENCE_DIR/cli-status.status"
if [[ "$cli_exit" != "0" ]]; then
    echo "AgentWake CLI status failed; inspect $EVIDENCE_DIR/cli-status.txt" >&2
    exit 1
fi

ui_output="$(mktemp "$EVIDENCE_DIR/.ui.XXXXXX")"
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
            set settingsMenuItemFound to false
            set settingsMenuPressed to false
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
                        perform action "AXPress" of itemRef
                        delay 0.3
                        repeat with menuItemRef in menu items of menu 1 of itemRef
                            set menuItemName to ""
                            try
                                set menuItemName to name of menuItemRef as text
                            end try
                            if menuItemName is not "" and menuItemName is not "missing value" then
                                set outputLines to outputLines & {"menuItem=" & menuItemName}
                            end if
                            if menuItemName is "Settings..." then
                                set settingsMenuItemFound to true
                                perform action "AXPress" of menuItemRef
                                set settingsMenuPressed to true
                            end if
                        end repeat
                    end if
                end repeat
            end repeat
            set outputLines to outputLines & {"statusItemFound=" & (statusItemFound as text)}
            set outputLines to outputLines & {"settingsMenuItemFound=" & (settingsMenuItemFound as text)}
            set outputLines to outputLines & {"settingsMenuPressed=" & (settingsMenuPressed as text)}
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
    echo "AgentWake accessibility menu bar capture failed; inspect $EVIDENCE_DIR/accessibility-menu-bar.txt" >&2
    exit 1
fi

settings_window_output="$(mktemp "$EVIDENCE_DIR/.settings-window.XXXXXX")"
if AGENTWAKE_EXPECTED_PID="$expected_pid" swift - >"$settings_window_output" 2>&1 <<'SWIFT'
import CoreGraphics
import Foundation

let expectedPID = Int(ProcessInfo.processInfo.environment["AGENTWAKE_EXPECTED_PID"] ?? "") ?? -1
var settingsWindowFound = false

if let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
    for info in windowInfo {
        let ownerPID = info[kCGWindowOwnerPID as String] as? Int ?? -1
        guard ownerPID == expectedPID else {
            continue
        }

        let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
        let windowName = info[kCGWindowName as String] as? String ?? ""
        let layer = info[kCGWindowLayer as String] as? Int ?? -1
        let isOnscreen = (info[kCGWindowIsOnscreen as String] as? Int ?? 0) == 1
        let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        print("windowOwnerPID=\(ownerPID)")
        print("windowOwnerName=\(ownerName)")
        print("windowName=\(windowName)")
        print("windowLayer=\(layer)")
        print("windowIsOnscreen=\(isOnscreen)")
        print("windowBounds=\(bounds)")

        if windowName == "AgentWake Settings" && layer == 0 && isOnscreen && width > 0 && height > 0 {
            settingsWindowFound = true
        }
    }
}

print("settingsWindowFound=\(settingsWindowFound)")
SWIFT
then
    settings_window_exit=0
else
    settings_window_exit=$?
fi
redact_metadata <"$settings_window_output" >"$EVIDENCE_DIR/settings-window.txt"
rm -f "$settings_window_output"
printf 'exitCode=%s\n' "$settings_window_exit" >"$EVIDENCE_DIR/settings-window.status"
if [[ "$settings_window_exit" != "0" ]]; then
    echo "AgentWake Settings window capture failed; inspect $EVIDENCE_DIR/settings-window.txt" >&2
    exit 1
fi

status_item_found=false
if grep -q '^statusItemFound=true$' "$EVIDENCE_DIR/accessibility-menu-bar.txt" &&
   grep -q "^unixID=$expected_pid$" "$EVIDENCE_DIR/accessibility-menu-bar.txt" &&
   grep -q '^statusItemName=AgentWake$' "$EVIDENCE_DIR/accessibility-menu-bar.txt" &&
   grep -q '^statusItemDescription=AgentWake status:' "$EVIDENCE_DIR/accessibility-menu-bar.txt"; then
    status_item_found=true
fi

closed_lid_mode_copy_found=false
if grep -q '^menuItem=Closed-Lid Mode unavailable$' "$EVIDENCE_DIR/accessibility-menu-bar.txt"; then
    closed_lid_mode_copy_found=true
fi

settings_menu_item_found=false
if grep -q '^settingsMenuItemFound=true$' "$EVIDENCE_DIR/accessibility-menu-bar.txt" &&
   grep -q '^settingsMenuPressed=true$' "$EVIDENCE_DIR/accessibility-menu-bar.txt"; then
    settings_menu_item_found=true
fi

settings_window_found=false
if grep -q '^settingsWindowFound=true$' "$EVIDENCE_DIR/settings-window.txt"; then
    settings_window_found=true
fi

cli_reachable=false
if grep -q '^AgentWake ' "$EVIDENCE_DIR/cli-status.txt"; then
    cli_reachable=true
fi

result="pass"
if [[ "$status_item_found" != true ||
      "$closed_lid_mode_copy_found" != true ||
      "$settings_menu_item_found" != true ||
      "$settings_window_found" != true ||
      "$cli_reachable" != true ]]; then
    result="fail"
fi

cat >"$OUTPUT_DIR/validation-config.txt" <<EOF
evidenceFormat=app-ui-smoke-v1
metadataRedacted=true
launchVerification=pass
expectedPID=$expected_pid
cliReachable=$cli_reachable
accessibilityStatusItemFound=$status_item_found
closedLidModeMenuCopyFound=$closed_lid_mode_copy_found
settingsMenuItemPressed=$settings_menu_item_found
settingsWindowFound=$settings_window_found
result=$result
EOF
redact_metadata <"$OUTPUT_DIR/validation-config.txt" >"$OUTPUT_DIR/validation-config.redacted"
mv "$OUTPUT_DIR/validation-config.redacted" "$OUTPUT_DIR/validation-config.txt"

cat >"$OUTPUT_DIR/README.md" <<'EOF'
# App UI Smoke

This package captures live local evidence that the staged AgentWake app bundle
launches, the CLI can reach it, and macOS Accessibility exposes an AgentWake menu
bar item with the current `Closed-Lid Mode unavailable` product copy. It also
opens the menu bar Settings item and verifies that CoreGraphics reports an onscreen,
non-empty `AgentWake Settings` window for the staged app process.

Evidence files:

- \`evidence/build-and-run.txt\`
- \`evidence/staged-process.txt\`
- \`evidence/cli-status.txt\`
- \`evidence/accessibility-menu-bar.txt\`
- \`evidence/settings-window.txt\`

This smoke does not prove a human can visually see the menu bar item on every
display configuration. It proves the app bundle process is running and the menu
bar item exists in the macOS accessibility tree, and that the Settings window is
present and onscreen in the macOS window list after selecting the Settings menu
item.
EOF

if [[ "$result" != "pass" ]]; then
    echo "AgentWake app UI smoke failed; inspect $OUTPUT_DIR" >&2
    exit 1
fi

echo "App UI smoke written to $OUTPUT_DIR"
