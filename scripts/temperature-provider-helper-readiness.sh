#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/temperature-provider-helper-readiness.sh --output-dir DIR
   or: scripts/temperature-provider-helper-readiness.sh DIR

Captures non-mutating helper-equivalent readiness evidence for the Bag Mode
temperature provider. The script never prompts for sudo; when not running as
root it uses `sudo -n` only so missing authorization is recorded as evidence
instead of blocking.

This is a preflight only. It does not prove closed-bag coverage, cadence, or
production provider reliability.
USAGE
}

OUTPUT_DIR=""

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

CAPTURE_TIMEOUT_SECONDS=${CLAWSHELL_TEMPERATURE_HELPER_READINESS_TIMEOUT_SECONDS:-1}
if ! [[ "$CAPTURE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$CAPTURE_TIMEOUT_SECONDS" -le 0 ]]; then
    echo "CLAWSHELL_TEMPERATURE_HELPER_READINESS_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 64
fi

if [[ -e "$OUTPUT_DIR" ]]; then
    if [[ -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
        echo "Output directory is not empty: $OUTPUT_DIR" >&2
        exit 73
    fi
fi

mkdir -p "$OUTPUT_DIR"

now_utc() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

capture_to() {
    local out_file=$1
    local status_file=$2
    shift 2
    local start
    local finish
    local pid
    local watchdog_pid
    local status=0
    local timed_out=false
    local timeout_marker="${status_file}.timeout"
    local cmd=("$@")

    rm -f "$timeout_marker"
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

    (
        sleep "$CAPTURE_TIMEOUT_SECONDS"
        if kill -0 "$pid" 2>/dev/null; then
            : >"$timeout_marker"
            kill "$pid" 2>/dev/null || true
            sleep 0.1
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
    ) &
    watchdog_pid=$!

    set +e
    wait "$pid" 2>/dev/null
    status=$?
    if kill -0 "$watchdog_pid" 2>/dev/null; then
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi
    set -e
    if [[ -f "$timeout_marker" ]]; then
        timed_out=true
        status=124
    fi
    rm -f "$timeout_marker"
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
        echo "timeoutSeconds=$CAPTURE_TIMEOUT_SECONDS"
        echo "timedOut=$timed_out"
        echo "exitCode=$status"
    } >"$status_file"
}

capture() {
    local name=$1
    shift
    capture_to "$OUTPUT_DIR/${name}.txt" "$OUTPUT_DIR/${name}.status" "$@"
}

status_value() {
    local name=$1
    local key=$2
    sed -n "s/^${key}=//p" "$OUTPUT_DIR/${name}.status" | head -n 1
}

effective_user_id="$(id -u)"
running_as_root=false
if [[ "$effective_user_id" == "0" ]]; then
    running_as_root=true
fi
hardware_arch="$(uname -m 2>/dev/null || echo unknown)"
powermetrics_path="$(command -v powermetrics 2>/dev/null || true)"

capture "sudo-noninteractive" sudo -n true
capture "pmset-battery" bash -o pipefail -c 'pmset -g batt 2>&1 | sed -E "s/\(id=[^)]+\)/(id=<redacted>)/g; s/id=[0-9A-Za-z_.:-]+/id=<redacted>/g"'
if [[ -n "$powermetrics_path" ]]; then
    if [[ "$running_as_root" == true ]]; then
        capture "powermetrics-helper-sample" "$powermetrics_path" -n 1 -i 1000 --samplers thermal
    else
        capture "powermetrics-helper-sample" sudo -n "$powermetrics_path" -n 1 -i 1000 --samplers thermal
    fi
else
    capture "powermetrics-helper-sample" /usr/bin/false
fi

sudo_exit_code="$(status_value "sudo-noninteractive" "exitCode")"
sudo_timed_out="$(status_value "sudo-noninteractive" "timedOut")"
powermetrics_exit_code="$(status_value "powermetrics-helper-sample" "exitCode")"
powermetrics_timed_out="$(status_value "powermetrics-helper-sample" "timedOut")"

sudo_noninteractive_available=false
if [[ "$running_as_root" == true || "$sudo_exit_code" == "0" ]]; then
    sudo_noninteractive_available=true
fi

battery_present=false
if grep -Eiq 'InternalBattery|Battery Power|Now drawing from' "$OUTPUT_DIR/pmset-battery.txt"; then
    battery_present=true
fi

powermetrics_available=false
if [[ -n "$powermetrics_path" ]]; then
    powermetrics_available=true
fi

numeric_temperature_output=false
if grep -Eiq '([0-9]+([.][0-9]+)?[[:space:]]*(C|°C|celsius))|((temperature|temp)[^0-9-]*-?[0-9]+([.][0-9]+)?)' "$OUTPUT_DIR/powermetrics-helper-sample.txt"; then
    numeric_temperature_output=true
fi

permission_state="unknown"
if [[ "$powermetrics_available" != true ]]; then
    permission_state="powermetricsMissing"
elif [[ "$powermetrics_timed_out" == "true" ]]; then
    permission_state="timedOut"
elif [[ "$powermetrics_exit_code" == "0" && "$running_as_root" == true ]]; then
    permission_state="availableAsRoot"
elif [[ "$powermetrics_exit_code" == "0" ]]; then
    permission_state="availableWithPasswordlessSudo"
elif grep -Eiq 'password is required|a terminal is required|no tty present' "$OUTPUT_DIR/powermetrics-helper-sample.txt"; then
    permission_state="sudoPasswordRequired"
elif grep -Eiq 'superuser|root|Operation not permitted|permission' "$OUTPUT_DIR/powermetrics-helper-sample.txt"; then
    permission_state="requiresRoot"
else
    permission_state="commandFailed"
fi

helper_sampling_candidate_available=false
if [[ "$numeric_temperature_output" == true &&
      ( "$permission_state" == "availableAsRoot" || "$permission_state" == "availableWithPasswordlessSudo" ) ]]; then
    helper_sampling_candidate_available=true
fi

cat >"$OUTPUT_DIR/validation-config.txt" <<EOF
evidenceFormat=temperature-helper-readiness-v1
capturedAtUtc=$(now_utc)
timeoutSeconds=$CAPTURE_TIMEOUT_SECONDS
metadataRedacted=true
runningAsRoot=$running_as_root
effectiveUserIdRedacted=true
hardwareArch=$hardware_arch
batteryPresent=$battery_present
powermetricsAvailable=$powermetrics_available
sudoNonInteractiveAvailable=$sudo_noninteractive_available
sudoNonInteractiveTimedOut=$sudo_timed_out
sudoNonInteractiveExitCode=$sudo_exit_code
powermetricsHelperPermissionState=$permission_state
powermetricsHelperTimedOut=$powermetrics_timed_out
powermetricsHelperExitCode=$powermetrics_exit_code
numericTemperatureOutput=$numeric_temperature_output
helperSamplingCandidateAvailable=$helper_sampling_candidate_available
providerProofReady=false
EOF

cat >"$OUTPUT_DIR/summary.md" <<EOF
# Temperature Helper Readiness Result

Captured at: $(now_utc)

This artifact is non-mutating. It does not intentionally heat hardware and it
never prompts for sudo.

## Result

- Running as root: \`$running_as_root\`
- Hardware architecture: \`$hardware_arch\`
- Battery present: \`$battery_present\`
- powermetrics available: \`$powermetrics_available\`
- sudo non-interactive available: \`$sudo_noninteractive_available\`
- powermetrics helper permission state: \`$permission_state\`
- powermetrics helper timed out: \`$powermetrics_timed_out\`
- Numeric temperature output observed: \`$numeric_temperature_output\`
- Helper sampling candidate available: \`$helper_sampling_candidate_available\`
- Provider proof ready: \`false\`

## Conclusion

This preflight only checks whether a helper-equivalent powermetrics sampling
path can run without a user-visible prompt. It does not prove freshness,
cadence, closed-bag coverage, fail-closed behavior, or production provider
reliability.
EOF

echo "Temperature helper readiness written to $OUTPUT_DIR"
