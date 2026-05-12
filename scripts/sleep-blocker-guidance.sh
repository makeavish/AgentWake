#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/sleep-blocker-guidance.sh [BLOCKERS_FILE]

Reads pmset assertion blocker lines and prints deduplicated cleanup guidance.
With no file, reads from stdin.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 64
fi

input="${1:-/dev/stdin}"
if [[ ! -r "$input" ]]; then
    echo "Blockers file is not readable: $input" >&2
    exit 66
fi

guidance_for_line() {
    local line="$1"
    local process

    process="$(printf '%s\n' "$line" | sed -n 's/^[[:space:]]*pid [0-9][0-9]*(\(.*\)): \[.*/\1/p')"
    process="${process:-unknown process}"

    if [[ "$line" == *"(WindowServer)"* && "$line" == *"UserIsActive"* ]]; then
        printf 'windowserver-user-active|WindowServer/UserIsActive: macOS is still seeing recent or continuing input. Wait without touching keyboard or trackpad, disconnect noisy Bluetooth/HID input devices if needed, then rerun the preflight.\n'
        return
    fi

    if [[ "$line" == *"(powerd)"* && "$line" == *"Powerd - Prevent sleep while display is on"* ]]; then
        printf 'powerd-display-on|powerd/display-on: display sleep has not happened yet. Put the display to sleep with `pmset displaysleepnow`, avoid waking it, then rerun the preflight. Do not kill powerd.\n'
        return
    fi

    if [[ "$line" == *"(sharingd)"* && "$line" == *"Handoff"* ]]; then
        printf 'sharingd-handoff|sharingd/Handoff: Continuity or Handoff is active. Stop the handoff activity or temporarily disable Handoff in System Settings > General > AirDrop & Handoff, then rerun the preflight.\n'
        return
    fi

    if [[ "$line" == *"(Slack)"* && "$line" == *"WebRTC"* ]]; then
        printf 'slack-webrtc|Slack/WebRTC: a call, huddle, screen share, or peer connection is active. Leave the call/huddle or quit Slack before validation.\n'
        return
    fi

    if [[ "$line" == *"(coreaudiod)"* ]]; then
        printf 'coreaudiod-audio|coreaudiod/audio: microphone, speaker, call, recording, or playback activity is preventing idle sleep. Stop the audio activity or quit the app using audio. Do not kill coreaudiod for validation.\n'
        return
    fi

    if [[ "$line" == *"(Codex)"* && "$line" == *"Electron"* ]]; then
        printf 'codex-electron|Codex/Electron: the Codex app is holding an Electron sleep assertion. For clean timed-idle evidence, quit Codex and run the validation from a plain terminal.\n'
        return
    fi

    if [[ "$process" == "Google Chrome"* || "$process" == "Chrome"* ]]; then
        printf 'chrome-generic|Chrome: close tabs with active calls, audio, downloads, screen sharing, or wake-locking pages, or quit Chrome before validation.\n'
        return
    fi

    printf 'generic-%s|%s: pause or quit the app/activity holding the sleep-preventing assertion, then rerun the preflight. For system daemons, clear the owning activity instead of killing the process.\n' "$process" "$process"
}

while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    guidance_for_line "$line"
done <"$input" | awk -F '|' '!seen[$1]++ { print "- " $2 }'
