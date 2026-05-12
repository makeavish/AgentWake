#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DURATION="${CLAWSHELL_TIMED_IDLE_DURATION:-90}"
LATE_OFFSET="${CLAWSHELL_TIMED_IDLE_LATE_OFFSET:-70}"

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -le 0 ]]; then
    echo "CLAWSHELL_TIMED_IDLE_DURATION must be a positive integer number of seconds" >&2
    exit 1
fi

if ! [[ "$LATE_OFFSET" =~ ^[0-9]+$ ]] || [[ "$LATE_OFFSET" -le 0 ]]; then
    echo "CLAWSHELL_TIMED_IDLE_LATE_OFFSET must be a positive integer number of seconds" >&2
    exit 1
fi

if [[ "$LATE_OFFSET" -ge "$DURATION" ]]; then
    echo "CLAWSHELL_TIMED_IDLE_LATE_OFFSET must be less than CLAWSHELL_TIMED_IDLE_DURATION" >&2
    exit 1
fi

work_dir="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

capture_pmset() {
    local name="$1"
    shift
    local output_file="$work_dir/$name.txt"
    local status=0

    "$@" >"$output_file" 2>&1 || status=$?
    if [[ "$status" -ne 0 ]]; then
        echo "Failed to capture $name with: $*" >&2
        cat "$output_file" >&2
        exit "$status"
    fi
}

capture_pmset "power-source" pmset -g batt
capture_pmset "power-settings" pmset -g custom
capture_pmset "pmset-assertions" pmset -g assertions

active_power_source="$(sed -n "s/^Now drawing from '\\(.*\\)'/\\1/p" "$work_dir/power-source.txt" | head -1)"
active_power_source="${active_power_source:-unknown}"

sleep_minutes="$(awk -v section="$active_power_source:" '
    $0 == section { in_section = 1; next }
    in_section && /^[^[:space:]].*:$/ { in_section = 0 }
    in_section && $1 == "sleep" { print $2; exit }
' "$work_dir/power-settings.txt")"
sleep_minutes="${sleep_minutes:-unknown}"

echo "Timed idle preflight"
echo "activePowerSource=$active_power_source"
echo "activeSleepMinutes=$sleep_minutes"
echo "durationSeconds=$DURATION"
echo "lateOffsetSeconds=$LATE_OFFSET"

threshold_ok=0
if [[ "$sleep_minutes" =~ ^[0-9]+$ ]] && [[ "$sleep_minutes" -gt 0 ]]; then
    idle_threshold_seconds=$((sleep_minutes * 60))
    echo "activeSleepThresholdSeconds=$idle_threshold_seconds"
    if [[ "$LATE_OFFSET" -gt "$idle_threshold_seconds" ]]; then
        echo "idleSleepThresholdExceeded=true"
        threshold_ok=1
    else
        echo "idleSleepThresholdExceeded=false"
    fi
elif [[ "$sleep_minutes" == "0" ]]; then
    echo "activeSleepThresholdSeconds=disabled"
    echo "idleSleepThresholdExceeded=not-applicable"
else
    echo "activeSleepThresholdSeconds=unknown"
    echo "idleSleepThresholdExceeded=unknown"
fi

grep -E '^[[:space:]]+pid .* (PreventUserIdleSystemSleep|PreventSystemSleep|NoIdleSleepAssertion|UserIsActive)' \
    "$work_dir/pmset-assertions.txt" \
    | grep -v "ClawShellPowerValidation" \
    >"$work_dir/non-clawshell-sleep-blockers.txt" || true
blocker_count="$(wc -l <"$work_dir/non-clawshell-sleep-blockers.txt" | tr -d '[:space:]')"
echo "nonClawShellSleepBlockerCount=$blocker_count"

if [[ "$blocker_count" != "0" ]]; then
    echo
    echo "Non-ClawShell sleep blockers:"
    cat "$work_dir/non-clawshell-sleep-blockers.txt"
    "$ROOT_DIR/scripts/sleep-blocker-guidance.sh" \
        "$work_dir/non-clawshell-sleep-blockers.txt" \
        >"$work_dir/non-clawshell-sleep-blocker-guidance.txt"
    if [[ -s "$work_dir/non-clawshell-sleep-blocker-guidance.txt" ]]; then
        echo
        echo "Suggested cleanup:"
        cat "$work_dir/non-clawshell-sleep-blocker-guidance.txt"
    fi
fi

if [[ "$threshold_ok" == "1" && "$blocker_count" == "0" ]]; then
    echo
    echo "Preflight passed: current settings are suitable for a conclusive timed-idle attempt."
    exit 0
fi

echo
echo "Preflight failed: current settings or blockers are not suitable for an immediate conclusive=true attempt."
exit 1
