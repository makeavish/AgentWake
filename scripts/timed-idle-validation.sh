#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-"$ROOT_DIR/.build/power-validation/timed-idle-$(date -u +%Y%m%dT%H%M%SZ)-$$"}"
DURATION="${CLAWSHELL_TIMED_IDLE_DURATION:-90}"
LATE_OFFSET="${CLAWSHELL_TIMED_IDLE_LATE_OFFSET:-70}"
READY_TIMEOUT="${CLAWSHELL_TIMED_IDLE_READY_TIMEOUT:-120}"
PMSET_LOG_LINES="${CLAWSHELL_TIMED_IDLE_PMSET_LOG_LINES:-300}"
READY_FILE="$OUTPUT_DIR/hold.ready"
HOLD_LOG="$OUTPUT_DIR/hold.log"

if [[ -d "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 | grep -q .; then
    echo "Output directory already exists and is not empty: $OUTPUT_DIR" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$READY_FILE"

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -le 0 ]]; then
    echo "CLAWSHELL_TIMED_IDLE_DURATION must be a positive integer number of seconds" >&2
    exit 1
fi

if ! [[ "$LATE_OFFSET" =~ ^[0-9]+$ ]] || [[ "$LATE_OFFSET" -le 0 ]] || [[ "$LATE_OFFSET" -ge "$DURATION" ]]; then
    echo "CLAWSHELL_TIMED_IDLE_LATE_OFFSET must be a positive integer less than duration" >&2
    exit 1
fi

if ! [[ "$READY_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$READY_TIMEOUT" -le 0 ]]; then
    echo "CLAWSHELL_TIMED_IDLE_READY_TIMEOUT must be a positive integer number of seconds" >&2
    exit 1
fi

if ! [[ "$PMSET_LOG_LINES" =~ ^[0-9]+$ ]] || [[ "$PMSET_LOG_LINES" -le 0 ]]; then
    echo "CLAWSHELL_TIMED_IDLE_PMSET_LOG_LINES must be a positive integer line count" >&2
    exit 1
fi

{
    echo "durationSeconds=$DURATION"
    echo "lateOffsetSeconds=$LATE_OFFSET"
    echo "readyTimeoutSeconds=$READY_TIMEOUT"
    echo "pmsetLogLines=$PMSET_LOG_LINES"
} >"$OUTPUT_DIR/validation-config.txt"
pmset -g batt >"$OUTPUT_DIR/power-source.txt" 2>&1 || true
pmset -g custom >"$OUTPUT_DIR/power-settings.txt" 2>&1 || true
active_power_source="$(sed -n "s/^Now drawing from '\\(.*\\)'/\\1/p" "$OUTPUT_DIR/power-source.txt" | head -1)"
active_power_source="${active_power_source:-unknown}"
sleep_minutes="$(awk -v section="$active_power_source:" '
    $0 == section { in_section = 1; next }
    in_section && /^[^[:space:]].*:$/ { in_section = 0 }
    in_section && $1 == "sleep" { print $2; exit }
' "$OUTPUT_DIR/power-settings.txt")"
sleep_minutes="${sleep_minutes:-unknown}"
echo "activePowerSource=$active_power_source" >>"$OUTPUT_DIR/validation-config.txt"
echo "activeSleepMinutes=$sleep_minutes" >>"$OUTPUT_DIR/validation-config.txt"

if [[ "$sleep_minutes" =~ ^[0-9]+$ ]] && [[ "$sleep_minutes" -gt 0 ]]; then
    idle_threshold_seconds=$((sleep_minutes * 60))
    echo "activeSleepThresholdSeconds=$idle_threshold_seconds" >>"$OUTPUT_DIR/validation-config.txt"
    if [[ "$LATE_OFFSET" -gt "$idle_threshold_seconds" ]]; then
        echo "idleSleepThresholdExceeded=true" >>"$OUTPUT_DIR/validation-config.txt"
    else
        echo "idleSleepThresholdExceeded=false" >>"$OUTPUT_DIR/validation-config.txt"
    fi
elif [[ "$sleep_minutes" == "0" ]]; then
    echo "activeSleepThresholdSeconds=disabled" >>"$OUTPUT_DIR/validation-config.txt"
    echo "idleSleepThresholdExceeded=not-applicable" >>"$OUTPUT_DIR/validation-config.txt"
else
    echo "activeSleepThresholdSeconds=unknown" >>"$OUTPUT_DIR/validation-config.txt"
    echo "idleSleepThresholdExceeded=unknown" >>"$OUTPUT_DIR/validation-config.txt"
fi

"$ROOT_DIR/scripts/pmset-snapshot.sh" "$OUTPUT_DIR/before"

bin_dir="$(swift build --show-bin-path)"
swift build --product ClawShellPowerValidation >"$OUTPUT_DIR/build.log" 2>&1
"$bin_dir/ClawShellPowerValidation" --duration "$DURATION" --ready-file "$READY_FILE" >"$HOLD_LOG" 2>&1 &
hold_pid="$!"

# shellcheck disable=SC2329
cleanup() {
    if kill -0 "$hold_pid" >/dev/null 2>&1; then
        kill "$hold_pid" >/dev/null 2>&1 || true
        wait "$hold_pid" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

for _ in $(seq 1 "$((READY_TIMEOUT * 10))"); do
    if [[ -f "$READY_FILE" ]]; then
        break
    fi
    if ! kill -0 "$hold_pid" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

if [[ ! -f "$READY_FILE" ]]; then
    echo "Normal assertion hold did not become ready" >&2
    cat "$HOLD_LOG" >&2 || true
    set +e
    wait "$hold_pid"
    hold_status="$?"
    set -e
    echo "holdExitStatus=$hold_status" >>"$OUTPUT_DIR/validation-config.txt"
    "$ROOT_DIR/scripts/pmset-snapshot.sh" "$OUTPUT_DIR/after"
    pmset -g log | tail -n "$PMSET_LOG_LINES" >"$OUTPUT_DIR/pmset-log-tail.txt" 2>&1 || true
    exit 1
fi

"$ROOT_DIR/scripts/pmset-snapshot.sh" "$OUTPUT_DIR/during-early"
sleep "$LATE_OFFSET"
"$ROOT_DIR/scripts/pmset-snapshot.sh" "$OUTPUT_DIR/during-late"

set +e
wait "$hold_pid"
hold_status="$?"
set -e
trap - EXIT

"$ROOT_DIR/scripts/pmset-snapshot.sh" "$OUTPUT_DIR/after"
pmset -g log | tail -n "$PMSET_LOG_LINES" >"$OUTPUT_DIR/pmset-log-tail.txt" 2>&1 || true
if [[ "${CLAWSHELL_TIMED_IDLE_FULL_PMSET_LOG:-0}" == "1" ]]; then
    pmset -g log >"$OUTPUT_DIR/pmset-log.txt" 2>&1 || true
fi
echo "holdExitStatus=$hold_status" >>"$OUTPUT_DIR/validation-config.txt"

if grep -q "ClawShellPowerValidation" "$OUTPUT_DIR/during-late/pmset-assertions.txt"; then
    late_clawshell_assertion="present"
else
    late_clawshell_assertion="missing"
fi
echo "lateClawShellAssertion=$late_clawshell_assertion" >>"$OUTPUT_DIR/validation-config.txt"

if grep -q "ClawShellPowerValidation" "$OUTPUT_DIR/after/pmset-assertions.txt"; then
    after_clawshell_assertion="present"
else
    after_clawshell_assertion="missing"
fi
echo "afterClawShellAssertion=$after_clawshell_assertion" >>"$OUTPUT_DIR/validation-config.txt"

grep -E '^[[:space:]]+pid .* (PreventUserIdleSystemSleep|PreventSystemSleep|NoIdleSleepAssertion|UserIsActive)' \
    "$OUTPUT_DIR/during-late/pmset-assertions.txt" \
    | grep -v "ClawShellPowerValidation" \
    >"$OUTPUT_DIR/non-clawshell-late-sleep-blockers.txt" || true
blocker_count="$(wc -l <"$OUTPUT_DIR/non-clawshell-late-sleep-blockers.txt" | tr -d '[:space:]')"
echo "nonClawShellLateSleepBlockerCount=$blocker_count" >>"$OUTPUT_DIR/validation-config.txt"
"$ROOT_DIR/scripts/sleep-blocker-guidance.sh" \
    "$OUTPUT_DIR/non-clawshell-late-sleep-blockers.txt" \
    >"$OUTPUT_DIR/non-clawshell-late-sleep-blocker-guidance.txt"

if grep -q '^idleSleepThresholdExceeded=true$' "$OUTPUT_DIR/validation-config.txt" \
    && [[ "$late_clawshell_assertion" == "present" ]] \
    && [[ "$after_clawshell_assertion" == "missing" ]] \
    && [[ "$blocker_count" == "0" ]] \
    && [[ "$hold_status" == "0" ]]; then
    echo "conclusive=true" >>"$OUTPUT_DIR/validation-config.txt"
else
    echo "conclusive=false" >>"$OUTPUT_DIR/validation-config.txt"
fi

cat >"$OUTPUT_DIR/README.txt" <<EOF
Timed idle validation

Duration: ${DURATION}s
Late snapshot offset: ${LATE_OFFSET}s
Active power source: ${active_power_source}
Active sleep setting minutes: ${sleep_minutes}

Phases:
- before: snapshot before ClawShell normal assertion hold
- during-early: snapshot immediately after the hold is ready
- during-late: snapshot after the late offset, intended to exceed the configured idle sleep interval
- after: snapshot after ClawShell releases the normal assertion

This harness does not change pmset settings. It documents observed behavior under the machine's current AC/battery profile. Treat the result as conclusive only when validation-config.txt has conclusive=true. When conclusive=false, inspect non-clawshell-late-sleep-blockers.txt, non-clawshell-late-sleep-blocker-guidance.txt, and the active sleep threshold fields.
EOF

echo "Timed idle validation written to $OUTPUT_DIR"
exit "$hold_status"
