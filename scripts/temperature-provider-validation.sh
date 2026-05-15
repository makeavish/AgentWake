#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/temperature-provider-validation.sh --output-dir DIR [--continue]
   or: scripts/temperature-provider-validation.sh DIR [--continue]

Captures non-destructive temperature-provider evidence for Bag Mode readiness.
The harness does not use sudo and does not intentionally heat hardware.

It records:
- ProcessInfo.thermalState
- pmset thermal warning status
- non-root powermetrics thermal sampler behavior
- AppleSmartBattery top-level temperature/update fields when available

The result is evidence only. It does not choose a production provider unless the
captured source satisfies numeric temperature, permission, freshness, and
closed-bag coverage requirements.
USAGE
}

OUTPUT_DIR=""
CONTINUE=false

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
        --continue)
            CONTINUE=true
            shift
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

if [[ -e "$OUTPUT_DIR" && "$CONTINUE" != true ]]; then
    if [[ -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
        echo "Output directory is not empty: $OUTPUT_DIR" >&2
        echo "Use --continue to append missing validation files." >&2
        exit 73
    fi
fi

TIMEOUT_SECONDS=${AGENTWAKE_TEMPERATURE_PROVIDER_TIMEOUT_SECONDS:-1}
PROCESSINFO_TIMEOUT_SECONDS=${AGENTWAKE_TEMPERATURE_PROVIDER_PROCESSINFO_TIMEOUT_SECONDS:-5}
FRESHNESS_SECONDS=${AGENTWAKE_TEMPERATURE_PROVIDER_FRESHNESS_SECONDS:-10}
SAMPLE_RATE_MS=${AGENTWAKE_TEMPERATURE_PROVIDER_SAMPLE_RATE_MS:-1000}

require_positive_integer() {
    local name=$1
    local value=$2
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
        echo "$name must be a positive integer" >&2
        exit 64
    fi
}

require_positive_integer "AGENTWAKE_TEMPERATURE_PROVIDER_TIMEOUT_SECONDS" "$TIMEOUT_SECONDS"
require_positive_integer "AGENTWAKE_TEMPERATURE_PROVIDER_PROCESSINFO_TIMEOUT_SECONDS" "$PROCESSINFO_TIMEOUT_SECONDS"
require_positive_integer "AGENTWAKE_TEMPERATURE_PROVIDER_FRESHNESS_SECONDS" "$FRESHNESS_SECONDS"
require_positive_integer "AGENTWAKE_TEMPERATURE_PROVIDER_SAMPLE_RATE_MS" "$SAMPLE_RATE_MS"

mkdir -p "$OUTPUT_DIR"

now_utc() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

write_kv() {
    if [[ "$WRITE_VALIDATION_CONFIG" != true ]]; then
        return 0
    fi
    printf "%s=%s\n" "$1" "$2" >> "$OUTPUT_DIR/validation-config.txt"
}

run_capture() {
    local name=$1
    local limit_seconds=$2
    shift 2

    local out_file="$OUTPUT_DIR/${name}.txt"
    local status_file="$OUTPUT_DIR/${name}.status"
    local start
    local finish
    local pid
    local exit_code=0
    local timed_out=false
    local cmd=("$@")

    if [[ "$CONTINUE" == true && ( -e "$out_file" || -e "$status_file" ) ]]; then
        if [[ -f "$out_file" && -f "$status_file" ]]; then
            return 0
        fi
        echo "Refusing to overwrite partial capture for $name in $OUTPUT_DIR" >&2
        exit 73
    fi

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
        if (( now - start >= limit_seconds )); then
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
    exit_code=$?
    set -e
    finish=$(date +%s)

    {
        printf "command="
        printf "%q" "${cmd[0]}"
        for part in "${cmd[@]:1}"; do
            printf " %q" "$part"
        done
        printf "\n"
        echo "startedAt=$(date -u -r "$start" +"%Y-%m-%dT%H:%M:%SZ")"
        echo "finishedAt=$(date -u -r "$finish" +"%Y-%m-%dT%H:%M:%SZ")"
        echo "durationSeconds=$(( finish - start ))"
        echo "timeoutSeconds=$limit_seconds"
        echo "timedOut=$timed_out"
        echo "exitCode=$exit_code"
    } >"$status_file"
}

status_value() {
    local name=$1
    local key=$2
    sed -n "s/^${key}=//p" "$OUTPUT_DIR/${name}.status" | head -n 1
}

WRITE_VALIDATION_CONFIG=false
if [[ "$CONTINUE" != true || ! -f "$OUTPUT_DIR/validation-config.txt" ]]; then
    : >"$OUTPUT_DIR/validation-config.txt"
    WRITE_VALIDATION_CONFIG=true
fi

if [[ "$CONTINUE" != true || ! -f "$OUTPUT_DIR/summary.md" ]]; then
    {
        echo "# Temperature Provider Validation Result"
        echo
        echo "Captured at: $(now_utc)"
        echo
        echo "This artifact is non-destructive and does not use sudo."
    } >"$OUTPUT_DIR/summary.md"
fi

if [[ "$CONTINUE" != true || ! -f "$OUTPUT_DIR/metadata.txt" ]]; then
    {
        echo "capturedAtUtc=$(now_utc)"
        echo "timeoutSeconds=$TIMEOUT_SECONDS"
        echo "processInfoProbeTimeoutSeconds=$PROCESSINFO_TIMEOUT_SECONDS"
        echo "freshnessSeconds=$FRESHNESS_SECONDS"
        echo "sampleRateMs=$SAMPLE_RATE_MS"
        echo "metadataRedacted=true"
        echo "osProductVersion=$(sw_vers -productVersion 2>/dev/null || echo unknown)"
        echo "osBuildVersion=$(sw_vers -buildVersion 2>/dev/null || echo unknown)"
        echo "machineArch=$(uname -m 2>/dev/null || echo unknown)"
        echo "effectiveUserId=$(id -u)"
    } >"$OUTPUT_DIR/metadata.txt"
fi

run_capture "processinfo-thermal-state" "$PROCESSINFO_TIMEOUT_SECONDS" swift -e 'import Foundation
let state = ProcessInfo.processInfo.thermalState
switch state {
case .nominal: print("thermalState=nominal")
case .fair: print("thermalState=fair")
case .serious: print("thermalState=serious")
case .critical: print("thermalState=critical")
@unknown default: print("thermalState=unknown")
}'

run_capture "pmset-therm" "$TIMEOUT_SECONDS" pmset -g therm

run_capture "powermetrics-thermal" "$TIMEOUT_SECONDS" powermetrics -n 1 -i "$SAMPLE_RATE_MS" --samplers thermal

run_capture "battery-temperature" "$TIMEOUT_SECONDS" bash -c '
ioreg -r -c AppleSmartBattery -l 2>/dev/null |
awk "
  /^[[:space:]]+\\\"Temperature\\\" = / { print; next }
  /^[[:space:]]+\\\"VirtualTemperature\\\" = / { print; next }
  /^[[:space:]]+\\\"UpdateTime\\\" = / { print; next }
"
'

process_state="missing"
if [[ -s "$OUTPUT_DIR/processinfo-thermal-state.txt" ]]; then
    process_state=$(sed -n 's/^thermalState=//p' "$OUTPUT_DIR/processinfo-thermal-state.txt" | head -n 1)
    [[ -n "$process_state" ]] || process_state="unparseable"
fi

pmset_has_numeric_temperature=false
if grep -Eiq '(-?[0-9]+([.][0-9]+)?[[:blank:]]*(°C|celsius|degrees?[[:blank:]]*C|C\>))|(\<(temperature|temp)\>[^0-9-]*-?[0-9]+([.][0-9]+)?)' "$OUTPUT_DIR/pmset-therm.txt" >/dev/null 2>&1; then
    pmset_has_numeric_temperature=true
fi

powermetrics_permission_state="unknown"
powermetrics_timed_out=$(status_value "powermetrics-thermal" "timedOut")
powermetrics_exit_code=$(status_value "powermetrics-thermal" "exitCode")
if [[ "$powermetrics_timed_out" == "true" ]]; then
    powermetrics_permission_state="timedOut"
elif grep -Eiq "superuser|root|Operation not permitted|permission" "$OUTPUT_DIR/powermetrics-thermal.txt" >/dev/null 2>&1; then
    powermetrics_permission_state="requiresRoot"
elif [[ "$powermetrics_exit_code" == "0" ]]; then
    powermetrics_permission_state="availableWithoutRoot"
fi

battery_temperature_raw=""
battery_virtual_temperature_raw=""
battery_update_time=""
if [[ -s "$OUTPUT_DIR/battery-temperature.txt" ]]; then
    battery_temperature_raw=$(sed -n 's/^[[:space:]]*"Temperature" = //p' "$OUTPUT_DIR/battery-temperature.txt" | head -n 1)
    battery_virtual_temperature_raw=$(sed -n 's/^[[:space:]]*"VirtualTemperature" = //p' "$OUTPUT_DIR/battery-temperature.txt" | head -n 1)
    battery_update_time=$(sed -n 's/^[[:space:]]*"UpdateTime" = //p' "$OUTPUT_DIR/battery-temperature.txt" | head -n 1)
fi

battery_temperature_celsius=""
battery_virtual_temperature_celsius=""
if [[ "$battery_temperature_raw" =~ ^[0-9]+$ ]]; then
    battery_temperature_celsius=$(awk -v raw="$battery_temperature_raw" 'BEGIN { printf "%.2f", (raw / 10.0) - 273.15 }')
fi
if [[ "$battery_virtual_temperature_raw" =~ ^[0-9]+$ ]]; then
    battery_virtual_temperature_celsius=$(awk -v raw="$battery_virtual_temperature_raw" 'BEGIN { printf "%.2f", (raw / 10.0) - 273.15 }')
fi

battery_update_age_seconds=""
battery_fresh=false
if [[ "$battery_update_time" =~ ^[0-9]+$ ]]; then
    current_epoch=$(date +%s)
    battery_update_age_seconds=$(( current_epoch - battery_update_time ))
    if (( battery_update_age_seconds >= 0 && battery_update_age_seconds <= FRESHNESS_SECONDS )); then
        battery_fresh=true
    fi
fi

write_kv "processInfoAvailable" "$([[ "$process_state" != missing ]] && echo true || echo false)"
write_kv "processInfoThermalState" "$process_state"
write_kv "processInfoNumericTemperature" "false"
write_kv "pmsetThermAvailable" "$([[ -s "$OUTPUT_DIR/pmset-therm.txt" ]] && echo true || echo false)"
write_kv "pmsetCurrentNumericTemperature" "$pmset_has_numeric_temperature"
write_kv "pmsetThermTimedOut" "$(status_value "pmset-therm" "timedOut")"
write_kv "pmsetThermExitCode" "$(status_value "pmset-therm" "exitCode")"
write_kv "powermetricsAvailable" "$([[ -x /usr/bin/powermetrics ]] && echo true || echo false)"
write_kv "powermetricsPermissionState" "$powermetrics_permission_state"
write_kv "powermetricsTimedOut" "$powermetrics_timed_out"
write_kv "powermetricsExitCode" "$powermetrics_exit_code"
write_kv "batteryIoregAvailable" "$([[ -s "$OUTPUT_DIR/battery-temperature.txt" ]] && echo true || echo false)"
write_kv "batteryTemperatureCelsius" "${battery_temperature_celsius:-missing}"
write_kv "batteryVirtualTemperatureCelsius" "${battery_virtual_temperature_celsius:-missing}"
write_kv "batteryUpdateTimeUnix" "${battery_update_time:-missing}"
write_kv "batteryUpdateAgeSeconds" "${battery_update_age_seconds:-missing}"
write_kv "batteryFreshWithin${FRESHNESS_SECONDS}Seconds" "$battery_fresh"
write_kv "candidateSelected" "none"
write_kv "bagModeTemperatureProviderReady" "false"

if [[ "$CONTINUE" != true || ! -f "$OUTPUT_DIR/summary-computed.md" ]]; then
cat >"$OUTPUT_DIR/summary-computed.md" <<SUMMARY

## Result

- ProcessInfo thermal state: \`$process_state\`
- ProcessInfo numeric temperature: not available
- pmset numeric temperature: \`$pmset_has_numeric_temperature\`
- powermetrics permission state: \`$powermetrics_permission_state\`
- Battery temperature Celsius: \`${battery_temperature_celsius:-missing}\`
- Battery virtual temperature Celsius: \`${battery_virtual_temperature_celsius:-missing}\`
- Battery update age seconds: \`${battery_update_age_seconds:-missing}\`
- Battery freshness within ${FRESHNESS_SECONDS}s: \`$battery_fresh\`

## Conclusion

No production Bag Mode temperature provider is selected by this harness.
ProcessInfo is permission-compatible but coarse and non-numeric. The non-root
powermetrics probe cannot be used by the app directly. AppleSmartBattery
temperature fields are useful context when present, but they do not prove
CPU/package or closed-bag thermal coverage and may not satisfy the 10 second
freshness requirement.

Production Bag Mode remains blocked until a no-membership helper or other
validated provider supplies fresh, permission-compatible thermal evidence with
fail-closed behavior.
SUMMARY
    cat "$OUTPUT_DIR/summary-computed.md" >>"$OUTPUT_DIR/summary.md"
fi

echo "Temperature provider validation written to $OUTPUT_DIR"
