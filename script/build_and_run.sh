#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AgentWake"
BUNDLE_ID="com.makeavish.AgentWake"
MIN_SYSTEM_VERSION="13.0"
SHORT_VERSION="0.0.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_VERSION="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || date -u +%Y%m%d%H%M)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
HOOK_ADAPTER_NAME="AgentWakeHookAdapter"
HOOK_ADAPTER_BINARY="$APP_MACOS/$HOOK_ADAPTER_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Resources/AgentWake.icns"
APP_ICON_NAME="AgentWake"

cd "$ROOT_DIR"

matching_app_pids() {
    local pid command
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        case "$command" in
            "$APP_BINARY"*|"$ROOT_DIR/.build/"*"/$APP_NAME"*)
                echo "$pid"
                ;;
        esac
    done < <(pgrep -x "$APP_NAME" || true)
}

stop_app() {
    local pid remaining

    for pid in $(matching_app_pids); do
        kill "$pid" >/dev/null 2>&1 || true
    done

    for _ in $(seq 1 50); do
        remaining="$(matching_app_pids)"
        if [[ -z "$remaining" ]]; then
            return 0
        fi
        sleep 0.1
    done

    for pid in $(matching_app_pids); do
        kill -KILL "$pid" >/dev/null 2>&1 || true
    done

    for _ in $(seq 1 20); do
        remaining="$(matching_app_pids)"
        if [[ -z "$remaining" ]]; then
            return 0
        fi
        sleep 0.1
    done

    echo "AgentWake did not stop cleanly: $remaining" >&2
    return 1
}

stage_app() {
    swift build --product "$APP_NAME"
    swift build --product "$HOOK_ADAPTER_NAME"
    local build_binary hook_adapter_build_binary
    build_binary="$(swift build --show-bin-path)/$APP_NAME"
    hook_adapter_build_binary="$(swift build --show-bin-path)/$HOOK_ADAPTER_NAME"

    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_MACOS" "$APP_RESOURCES"
    cp "$build_binary" "$APP_BINARY"
    cp "$hook_adapter_build_binary" "$HOOK_ADAPTER_BINARY"
    cp "$APP_ICON_SOURCE" "$APP_RESOURCES/$APP_ICON_NAME.icns"
    chmod +x "$APP_BINARY" "$HOOK_ADAPTER_BINARY"

    cat >"$INFO_PLIST" <<PLIST
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
}

open_app() {
    if [[ "${AGENTWAKE_SKIP_ONBOARDING:-0}" == "1" ]]; then
        AGENTWAKE_SKIP_ONBOARDING=1 "$APP_BINARY" >/dev/null 2>&1 &
    else
        /usr/bin/open -n "$APP_BUNDLE"
    fi
}

verify_app() {
    local pid command found
    found=0
    for pid in $(matching_app_pids); do
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        case "$command" in
            "$APP_BINARY"*)
                found=1
                ;;
        esac
    done

    [[ "$found" == "1" ]]
    [[ -x "$APP_BINARY" ]]
    [[ -x "$HOOK_ADAPTER_BINARY" ]]
}

case "$MODE" in
    run)
        stop_app
        stage_app
        open_app
        ;;
    --debug|debug)
        stop_app
        stage_app
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        stop_app
        stage_app
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        stop_app
        stage_app
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        stop_app
        stage_app
        AGENTWAKE_SKIP_ONBOARDING=1 open_app
        sleep 2
        verify_app
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
