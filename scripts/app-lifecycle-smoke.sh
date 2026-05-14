#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR=""
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClawShell"
HOOK_ADAPTER_NAME="ClawShellHookAdapter"
BUNDLE_ID="com.clawshell.app"
MIN_SYSTEM_VERSION="13.0"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
HOOK_ADAPTER_BINARY="$APP_MACOS/$HOOK_ADAPTER_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

usage() {
    cat <<'EOF'
Usage: scripts/app-lifecycle-smoke.sh --output-dir DIR

Builds and launches the staged ClawShell app bundle, then captures live local
evidence for AppleEvent quit/relaunch, SIGTERM/relaunch, and force-kill/relaunch
behavior. This opens ClawShell and terminates only the staged app process owned
by this repository.
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

stage_app_bundle() {
    local temp_output exit_code build_dir

    temp_output="$(mktemp "$EVIDENCE_DIR/.stage-app.XXXXXX")"
    exit_code=0
    {
        swift build --package-path "$ROOT_DIR" --product "$APP_NAME" &&
        swift build --package-path "$ROOT_DIR" --product "$HOOK_ADAPTER_NAME" &&
        build_dir="$(swift build --package-path "$ROOT_DIR" --show-bin-path)" &&
        rm -rf "$APP_BUNDLE" &&
        mkdir -p "$APP_MACOS" &&
        cp "$build_dir/$APP_NAME" "$APP_BINARY" &&
        cp "$build_dir/$HOOK_ADAPTER_NAME" "$HOOK_ADAPTER_BINARY" &&
        chmod +x "$APP_BINARY" "$HOOK_ADAPTER_BINARY" &&
        cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
    } >"$temp_output" 2>&1 || exit_code=$?

    redact_metadata <"$temp_output" >"$EVIDENCE_DIR/stage-app.txt"
    rm -f "$temp_output"
    printf 'exitCode=%s\n' "$exit_code" >"$EVIDENCE_DIR/stage-app.status"
    return "$exit_code"
}

staged_pids() {
    local candidate_pid candidate_command
    while read -r candidate_pid; do
        [[ -n "$candidate_pid" ]] || continue
        candidate_command="$(ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
        case "$candidate_command" in
            "$APP_BINARY"*)
                printf '%s\n' "$candidate_pid"
                ;;
        esac
    done < <(pgrep -x ClawShell || true)
}

clawshell_pids() {
    pgrep -x ClawShell || true
}

stop_existing_staged_app() {
    local candidate_pid remaining

    for candidate_pid in $(staged_pids); do
        kill "$candidate_pid" >/dev/null 2>&1 || true
    done

    if wait_for_staged_process_count 0; then
        return 0
    fi

    for candidate_pid in $(staged_pids); do
        kill -KILL "$candidate_pid" >/dev/null 2>&1 || true
    done

    if wait_for_staged_process_count 0; then
        return 0
    fi

    remaining="$(staged_pids | paste -sd ',' -)"
    echo "Could not stop staged ClawShell process(es): $remaining" >&2
    return 1
}

signal_staged_pid() {
    local pid="$1"
    local signal_name="$2"
    local label="$3"
    local command

    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command" in
        "$APP_BINARY"*)
            ;;
        *)
            echo "Refusing to send $signal_name during $label; PID $pid is not the staged ClawShell process" >&2
            return 1
            ;;
    esac

    case "$signal_name" in
        TERM)
            kill "$pid"
            ;;
        KILL)
            kill -KILL "$pid"
            ;;
        *)
            echo "Unsupported signal: $signal_name" >&2
            return 2
            ;;
    esac
}

appleevent_quit_staged_pid() {
    local pid="$1"
    local label="$2"
    local command clawshell_processes clawshell_process_count temp_output exit_code

    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command" in
        "$APP_BINARY"*)
            ;;
        *)
            echo "Refusing AppleEvent quit during $label; PID $pid is not the staged ClawShell process" >&2
            return 1
            ;;
    esac

    clawshell_processes="$(clawshell_pids)"
    clawshell_process_count="$(printf '%s\n' "$clawshell_processes" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$clawshell_process_count" != "1" || "$clawshell_processes" != "$pid" ]]; then
        {
            printf 'expectedPID=%s\n' "$pid"
            printf 'clawshellPIDs=%s\n' "$(printf '%s\n' "$clawshell_processes" | paste -sd ',' -)"
        } >"$EVIDENCE_DIR/$label-appleevent-quit-preflight.txt"
        echo "Refusing AppleEvent quit during $label; expected the staged app to be the only ClawShell process" >&2
        return 1
    fi

    temp_output="$(mktemp "$EVIDENCE_DIR/.$label-appleevent-quit.XXXXXX")"
    if /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >"$temp_output" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi
    redact_metadata <"$temp_output" >"$EVIDENCE_DIR/$label-appleevent-quit.txt"
    rm -f "$temp_output"
    printf 'exitCode=%s\n' "$exit_code" >"$EVIDENCE_DIR/$label-appleevent-quit.status"
    return "$exit_code"
}

single_staged_pid() {
    local pids count
    pids="$(staged_pids)"
    count="$(printf '%s\n' "$pids" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$count" != "1" ]]; then
        return 1
    fi
    printf '%s\n' "$pids"
}

wait_for_staged_process_count() {
    local expected_count="$1"
    local count
    for _ in $(seq 1 100); do
        count="$(staged_pids | sed '/^$/d' | wc -l | tr -d ' ')"
        if [[ "$count" == "$expected_count" ]]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

capture_process_snapshot() {
    local name="$1"
    {
        printf 'appBinary=%s\n' "$APP_BINARY"
        printf 'stagedPIDs='
        staged_pids | paste -sd ',' -
        printf '\n'
    } | redact_metadata >"$EVIDENCE_DIR/$name.txt"
}

run_cli_status() {
    local name="$1"
    capture_command "$name" swift run --package-path "$ROOT_DIR" ClawShellCLI status
}

expect_cli_running() {
    local name="$1"
    if ! run_cli_status "$name"; then
        echo "Expected ClawShell CLI status to reach the app during $name" >&2
        return 1
    fi
    grep -q '^ClawShell ' "$EVIDENCE_DIR/$name.txt"
}

expect_cli_not_running() {
    local name="$1"
    if run_cli_status "$name"; then
        echo "Expected ClawShell CLI status to fail after stop during $name" >&2
        return 1
    fi
    grep -q 'ClawShell is not running' "$EVIDENCE_DIR/$name.txt"
}

launch_staged_app() {
    local name="$1"
    if ! capture_command "$name-open" /usr/bin/open -n "$APP_BUNDLE"; then
        echo "Staged app launch failed during $name" >&2
        return 1
    fi
    if ! wait_for_staged_process_count 1; then
        capture_process_snapshot "$name-processes"
        echo "Timed out waiting for one staged ClawShell process during $name" >&2
        return 1
    fi
    if ! single_staged_pid >"$EVIDENCE_DIR/$name.pid"; then
        capture_process_snapshot "$name-processes"
        echo "Expected exactly one staged ClawShell process during $name" >&2
        return 1
    fi
    capture_process_snapshot "$name-processes"
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

if ! stage_app_bundle; then
    echo "Staged app build failed; inspect $EVIDENCE_DIR/stage-app.txt" >&2
    exit 1
fi
stop_existing_staged_app
capture_process_snapshot "before-initial-launch-processes"

launch_staged_app "initial-launch"
expect_cli_running "initial-cli-status"

initial_pid="$(cat "$EVIDENCE_DIR/initial-launch.pid")"
appleevent_quit_staged_pid "$initial_pid" "appleevent-quit"
wait_for_staged_process_count 0
capture_process_snapshot "after-appleevent-quit-processes"
expect_cli_not_running "after-appleevent-quit-cli-status"

launch_staged_app "relaunch-after-appleevent-quit"
expect_cli_running "relaunch-after-appleevent-quit-cli-status"

appleevent_relaunch_pid="$(cat "$EVIDENCE_DIR/relaunch-after-appleevent-quit.pid")"
signal_staged_pid "$appleevent_relaunch_pid" TERM "sigterm stop"
wait_for_staged_process_count 0
capture_process_snapshot "after-sigterm-stop-processes"
expect_cli_not_running "after-sigterm-stop-cli-status"

launch_staged_app "relaunch-after-sigterm-stop"
expect_cli_running "relaunch-after-sigterm-stop-cli-status"

relaunch_pid="$(cat "$EVIDENCE_DIR/relaunch-after-sigterm-stop.pid")"
signal_staged_pid "$relaunch_pid" KILL "crash stop"
wait_for_staged_process_count 0
capture_process_snapshot "after-crash-stop-processes"
expect_cli_not_running "after-crash-stop-cli-status"

launch_staged_app "relaunch-after-crash-stop"
expect_cli_running "relaunch-after-crash-stop-cli-status"

final_pid="$(cat "$EVIDENCE_DIR/relaunch-after-crash-stop.pid")"

cat >"$OUTPUT_DIR/validation-config.txt" <<EOF
evidenceFormat=app-lifecycle-smoke-v1
metadataRedacted=true
initialLaunchPID=$initial_pid
appleEventQuitObserved=true
relaunchAfterAppleEventQuitPID=$appleevent_relaunch_pid
sigtermStopObserved=true
relaunchAfterSIGTERMStopPID=$relaunch_pid
crashStopObserved=true
relaunchAfterCrashStopPID=$final_pid
result=pass
EOF
redact_metadata <"$OUTPUT_DIR/validation-config.txt" >"$OUTPUT_DIR/validation-config.redacted"
mv "$OUTPUT_DIR/validation-config.redacted" "$OUTPUT_DIR/validation-config.txt"

cat >"$OUTPUT_DIR/README.md" <<'EOF'
# App Lifecycle Smoke

This package captures live local evidence that the staged ClawShell app bundle
can launch, quit through AppleEvent, relaunch, stop after SIGTERM, relaunch,
tolerate a force-kill, and relaunch again while the CLI reachability state
follows the process lifecycle.

This smoke only targets the staged app process whose command starts with
`dist/ClawShell.app/Contents/MacOS/ClawShell`. It does not terminate unrelated
ClawShell installs, does not reboot the machine, and does not exercise Bag Mode
while armed.
EOF

echo "App lifecycle smoke written to $OUTPUT_DIR"
