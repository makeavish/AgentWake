#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/temperature-provider-powermetrics-proof.sh ..." >&2
    exit 2
fi
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/temperature-provider-powermetrics-proof.sh --output-dir DIR [--case-id ID]
   or: scripts/temperature-provider-powermetrics-proof.sh DIR

Builds a no-prompt powermetrics proof-attempt package for #25. The harness is
non-mutating and never prompts for sudo; when not running as root it uses
`sudo -n` so missing helper/root authorization is captured as evidence instead
of blocking.

This is not complete provider proof by itself. It records the command path,
permission behavior, timeout behavior, ProcessInfo supplemental signal, and
numeric output when available. Freshness, cadence, closed-bag coverage, and
fail-closed proof rows intentionally remain TODO until real helper/root samples
are captured.
USAGE
}

OUTPUT_DIR=""
CASE_ID="apple-silicon-powermetrics-proof-attempt"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            if [[ $# -lt 2 ]]; then
                echo "--output-dir requires a value" >&2
                exit 64
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --case-id)
            if [[ $# -lt 2 ]]; then
                echo "--case-id requires a value" >&2
                exit 64
            fi
            CASE_ID="$2"
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
            OUTPUT_DIR="$1"
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
if [[ -e "$OUTPUT_DIR" && -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    echo "Output directory is not empty: $OUTPUT_DIR" >&2
    exit 73
fi

TIMEOUT_SECONDS=${CLAWSHELL_TEMPERATURE_PROOF_TIMEOUT_SECONDS:-1}
FRESHNESS_SECONDS=${CLAWSHELL_TEMPERATURE_PROOF_FRESHNESS_SECONDS:-10}
ACTIVE_CADENCE_SECONDS=${CLAWSHELL_TEMPERATURE_PROOF_ACTIVE_CADENCE_SECONDS:-5}
IDLE_CADENCE_SECONDS=${CLAWSHELL_TEMPERATURE_PROOF_IDLE_CADENCE_SECONDS:-30}
SAMPLE_RATE_MS=${CLAWSHELL_TEMPERATURE_PROOF_SAMPLE_RATE_MS:-1000}

require_positive_integer() {
    local name="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
        echo "$name must be a positive integer" >&2
        exit 64
    fi
}

require_positive_integer "CLAWSHELL_TEMPERATURE_PROOF_TIMEOUT_SECONDS" "$TIMEOUT_SECONDS"
require_positive_integer "CLAWSHELL_TEMPERATURE_PROOF_FRESHNESS_SECONDS" "$FRESHNESS_SECONDS"
require_positive_integer "CLAWSHELL_TEMPERATURE_PROOF_ACTIVE_CADENCE_SECONDS" "$ACTIVE_CADENCE_SECONDS"
require_positive_integer "CLAWSHELL_TEMPERATURE_PROOF_IDLE_CADENCE_SECONDS" "$IDLE_CADENCE_SECONDS"
require_positive_integer "CLAWSHELL_TEMPERATURE_PROOF_SAMPLE_RATE_MS" "$SAMPLE_RATE_MS"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
EVIDENCE_DIR="$OUTPUT_DIR/evidence"
mkdir -p "$EVIDENCE_DIR"

now_utc() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

capture_to() {
    local out_file="$1"
    local status_file="$2"
    local limit_seconds="$3"
    shift 3
    local start finish pid watchdog_pid status timed_out timeout_marker
    local cmd=("$@")
    timed_out=false
    timeout_marker="${status_file}.timeout"

    rm -f "$timeout_marker"
    start="$(date +%s)"
    set +m
    (
        child_pid=""
        trap 'if [[ -n "$child_pid" ]]; then kill "$child_pid" 2>/dev/null || true; sleep 0.1; if kill -0 "$child_pid" 2>/dev/null; then kill -KILL "$child_pid" 2>/dev/null || true; fi; wait "$child_pid" 2>/dev/null || true; fi; exit 124' TERM
        "${cmd[@]}" &
        child_pid=$!
        wait "$child_pid"
    ) >"$out_file" 2>&1 &
    pid=$!

    (
        sleep "$limit_seconds"
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
    finish="$(date +%s)"

    {
        printf 'command='
        printf '%q' "${cmd[0]}"
        for part in "${cmd[@]:1}"; do
            printf ' %q' "$part"
        done
        printf '\n'
        echo "startedAt=$(date -u -r "$start" +"%Y-%m-%dT%H:%M:%SZ")"
        echo "finishedAt=$(date -u -r "$finish" +"%Y-%m-%dT%H:%M:%SZ")"
        echo "durationSeconds=$(( finish - start ))"
        echo "timeoutSeconds=$limit_seconds"
        echo "timedOut=$timed_out"
        echo "exitCode=$status"
    } >"$status_file"
}

capture() {
    local name="$1"
    local limit_seconds="$2"
    shift 2
    capture_to "$EVIDENCE_DIR/${name}.txt" "$EVIDENCE_DIR/${name}.status" "$limit_seconds" "$@"
}

status_value() {
    local name="$1"
    local key="$2"
    sed -n "s/^${key}=//p" "$EVIDENCE_DIR/${name}.status" | head -n 1
}

manifest_row() {
    local check_id="$1"
    local status="$2"
    local path="$3"
    local note="$4"
    printf '%s\t%s\t%s\t%s\n' "$check_id" "$status" "$path" "$note"
}

effective_user_id="$(id -u)"
running_as_root=false
if [[ "$effective_user_id" == "0" ]]; then
    running_as_root=true
fi

hardware_arch="$(uname -m 2>/dev/null || echo unknown)"
cpu="Intel"
if [[ "$hardware_arch" == arm64* ]]; then
    cpu="Apple Silicon"
fi

hardware_class="unknown"
if pmset -g batt 2>/dev/null | grep -Eiq 'InternalBattery|Battery Power|Now drawing from'; then
    hardware_class="MacBook"
else
    hardware_class="desktop"
fi

powermetrics_path="$(command -v powermetrics 2>/dev/null || true)"

capture "processinfo-supplemental-signal" 5 swift -e 'import Foundation
let state = ProcessInfo.processInfo.thermalState
switch state {
case .nominal: print("thermalState=nominal")
case .fair: print("thermalState=fair")
case .serious: print("thermalState=serious")
case .critical: print("thermalState=critical")
@unknown default: print("thermalState=unknown")
}'

capture "sudo-noninteractive" "$TIMEOUT_SECONDS" sudo -n true
sudo_exit_code="$(status_value "sudo-noninteractive" "exitCode")"
sudo_timed_out="$(status_value "sudo-noninteractive" "timedOut")"
sudo_noninteractive_available=false
if [[ "$running_as_root" == true || "$sudo_exit_code" == "0" ]]; then
    sudo_noninteractive_available=true
fi

sampling_mode="missing"
if [[ -n "$powermetrics_path" ]]; then
    if [[ "$running_as_root" == true ]]; then
        sampling_mode="root"
        capture "numeric-temperature-output" "$TIMEOUT_SECONDS" "$powermetrics_path" -n 1 -i "$SAMPLE_RATE_MS" --samplers thermal
    else
        sampling_mode="sudo-noninteractive"
        capture "numeric-temperature-output" "$TIMEOUT_SECONDS" sudo -n "$powermetrics_path" -n 1 -i "$SAMPLE_RATE_MS" --samplers thermal
    fi
else
    capture "numeric-temperature-output" "$TIMEOUT_SECONDS" /usr/bin/false
fi

powermetrics_exit_code="$(status_value "numeric-temperature-output" "exitCode")"
powermetrics_timed_out="$(status_value "numeric-temperature-output" "timedOut")"
powermetrics_available=false
if [[ -n "$powermetrics_path" ]]; then
    powermetrics_available=true
fi

sample_completed=false
if [[ "$powermetrics_exit_code" == "0" && "$powermetrics_timed_out" != "true" ]]; then
    sample_completed=true
fi

numeric_temperature_observed=false
if grep -Eiq '([0-9]+([.][0-9]+)?[[:space:]]*(C|°C|celsius))|((temperature|temp)[^0-9-]*-?[0-9]+([.][0-9]+)?)' "$EVIDENCE_DIR/numeric-temperature-output.txt"; then
    numeric_temperature_observed=true
fi

permission_state="unknown"
if [[ "$powermetrics_available" != true ]]; then
    permission_state="powermetricsMissing"
elif [[ "$powermetrics_timed_out" == "true" ]]; then
    permission_state="timedOut"
elif [[ "$sample_completed" == true && "$running_as_root" == true ]]; then
    permission_state="availableAsRoot"
elif [[ "$sample_completed" == true ]]; then
    permission_state="nonInteractiveSudoSucceeded"
elif grep -Eiq 'password is required|a terminal is required|no tty present' "$EVIDENCE_DIR/numeric-temperature-output.txt"; then
    permission_state="sudoPasswordRequired"
elif grep -Eiq 'superuser|root|Operation not permitted|permission' "$EVIDENCE_DIR/numeric-temperature-output.txt"; then
    permission_state="requiresRoot"
else
    permission_state="commandFailed"
fi

helper_owned=false
if [[ "$permission_state" == "availableAsRoot" ]]; then
    helper_owned=true
fi

numeric_cutoff_source=false

result="inconclusive"
if [[ "$permission_state" == "sudoPasswordRequired" ||
      "$permission_state" == "requiresRoot" ||
      "$permission_state" == "powermetricsMissing" ||
      "$permission_state" == "timedOut" ]]; then
    result="fail"
fi

freshest_age="TODO - freshness samples not captured"

cat >"$EVIDENCE_DIR/provider-command-or-api.txt" <<EOF
providerSource=powermetrics
powermetricsPath=${powermetrics_path:-missing}
samplingMode=$sampling_mode
sampleCommandTimeoutSeconds=$TIMEOUT_SECONDS
sampleRateMs=$SAMPLE_RATE_MS
usesPromptlessSudo=true
sudoCommand=sudo -n <powermetrics> -n 1 -i $SAMPLE_RATE_MS --samplers thermal
EOF

cat >"$EVIDENCE_DIR/helper-ownership-context.txt" <<EOF
runningAsRoot=$running_as_root
sudoNonInteractiveAvailable=$sudo_noninteractive_available
sudoNonInteractiveTimedOut=$sudo_timed_out
sudoNonInteractiveExitCode=$sudo_exit_code
samplingMode=$sampling_mode
helperOwnedOrEquivalent=$helper_owned
permissionState=$permission_state
EOF

cat >"$EVIDENCE_DIR/permission-behavior.txt" <<EOF
permissionState=$permission_state
powermetricsAvailable=$powermetrics_available
powermetricsTimedOut=$powermetrics_timed_out
powermetricsExitCode=$powermetrics_exit_code
sampleCompleted=$sample_completed
numericTemperatureObserved=$numeric_temperature_observed
sudoNonInteractiveAvailable=$sudo_noninteractive_available

See numeric-temperature-output.txt and numeric-temperature-output.status for
the captured powermetrics attempt.
EOF

cat >"$EVIDENCE_DIR/no-user-visible-prompts.txt" <<EOF
noUserVisiblePrompts=true
The harness never invokes promptable sudo. It uses sudo -n only when not root,
so missing authorization is recorded as command output instead of showing a
password prompt during Bag Mode.
EOF

cat >"$EVIDENCE_DIR/timeout-enforcement.txt" <<EOF
timeoutSeconds=$TIMEOUT_SECONDS
powermetricsTimedOut=$powermetrics_timed_out
powermetricsExitCode=$powermetrics_exit_code
statusFile=evidence/numeric-temperature-output.status
EOF

cat >"$EVIDENCE_DIR/logs.txt" <<EOF
capturedAtUtc=$(now_utc)
caseId=$CASE_ID
macOSVersion=$(sw_vers -productVersion 2>/dev/null || echo unknown)
hardwareArch=$hardware_arch
hardwareClass=$hardware_class
permissionState=$permission_state
sampleCompleted=$sample_completed
numericTemperatureObserved=$numeric_temperature_observed
numericCutoffSource=$numeric_cutoff_source
providerProofReady=false
EOF

cat >"$OUTPUT_DIR/validation-config.txt" <<EOF
evidenceFormat=temperature-provider-proof-v1
metadataRedacted=true
macOSVersion=$(sw_vers -productVersion 2>/dev/null || echo unknown)
cpu=$cpu
hardwareClass=$hardware_class
providerSource=powermetrics
helperOwned=$helper_owned
processInfoSupplementalOnly=true
numericCutoffSource=$numeric_cutoff_source
noUserVisiblePrompts=true
freshnessMaxAgeSeconds=$FRESHNESS_SECONDS
activeCadenceSeconds=$ACTIVE_CADENCE_SECONDS
idleCadenceSeconds=$IDLE_CADENCE_SECONDS
timeoutSeconds=$TIMEOUT_SECONDS
closedBagCoverage=insufficient
failClosedContract=unverified
result=$result
caseId=$CASE_ID
powermetricsPermissionState=$permission_state
sampleCompleted=$sample_completed
numericTemperatureObserved=$numeric_temperature_observed
providerProofReady=false
EOF

cat >"$OUTPUT_DIR/manual-result.md" <<EOF
# Temperature Provider Proof Result

## Provider Case
- Case ID: $CASE_ID
- Provider source: powermetrics
- Helper-owned provider: $([[ "$helper_owned" == true ]] && echo yes || echo TODO - helper/root-equivalent sampling unavailable)
- Numeric cutoff source: TODO - numeric output is diagnostic until helper/root freshness and cadence are proven
- No user-visible prompts: yes
- ProcessInfo role: supplemental-only

## Sampling
- Freshest reading age seconds: $freshest_age
- Active cadence seconds: TODO - capture two or more samples at ${ACTIVE_CADENCE_SECONDS}s spacing
- Idle cadence seconds: TODO - capture two or more samples at ${IDLE_CADENCE_SECONDS}s spacing
- Timeout seconds: $TIMEOUT_SECONDS

## Coverage
- Closed-bag coverage: insufficient
- Fail-closed cases recorded: TODO

## Conclusion
- Result: $result
EOF

numeric_status="TODO"
numeric_path=""
numeric_note="Numeric powermetrics output was not captured; inspect permission-behavior evidence"
if [[ "$sample_completed" == true && "$numeric_temperature_observed" == true ]]; then
    numeric_status="evidence"
    numeric_path="evidence/numeric-temperature-output.txt"
    numeric_note="diagnostic numeric powermetrics output captured; not promoted to cutoff proof"
fi

{
    printf 'checkId\tstatus\tevidencePath\tnote\n'
    manifest_row "provider-command-or-api" "evidence" "evidence/provider-command-or-api.txt" "powermetrics command path captured"
    manifest_row "helper-ownership-context" "evidence" "evidence/helper-ownership-context.txt" "root/helper-equivalent context captured"
    manifest_row "numeric-temperature-output" "$numeric_status" "$numeric_path" "$numeric_note"
    manifest_row "freshness-samples" "TODO" "" "Capture repeated helper/root samples and compute max age"
    manifest_row "active-cadence-samples" "TODO" "" "Capture samples at active cadence"
    manifest_row "idle-cadence-samples" "TODO" "" "Capture samples at idle cadence"
    manifest_row "timeout-enforcement" "evidence" "evidence/timeout-enforcement.txt" "sample timeout behavior captured"
    manifest_row "timeout-fail-closed" "TODO" "" "Attach policy evidence that timeout blocks/releases Bag Mode"
    manifest_row "permission-behavior" "evidence" "evidence/permission-behavior.txt" "permission behavior captured"
    manifest_row "no-user-visible-prompts" "evidence" "evidence/no-user-visible-prompts.txt" "sudo -n only; no promptable sudo"
    manifest_row "closed-bag-coverage-analysis" "TODO" "" "Analyze whether powermetrics reading covers closed-bag risk"
    manifest_row "processinfo-supplemental-signal" "evidence" "evidence/processinfo-supplemental-signal.txt" "ProcessInfo thermalState captured as supplemental signal"
    manifest_row "safety-contract-tests" "TODO" "" "Attach mocked safety contract run for selected provider"
    manifest_row "unavailable-fail-closed" "TODO" "" "Attach unavailable provider fail-closed evidence"
    manifest_row "stale-fail-closed" "TODO" "" "Attach stale provider fail-closed evidence"
    manifest_row "permission-denied-fail-closed" "TODO" "" "Attach permission denied fail-closed evidence"
    manifest_row "parse-failed-fail-closed" "TODO" "" "Attach parse failure fail-closed evidence"
    manifest_row "helper-crashed-fail-closed" "TODO" "" "Attach helper crash fail-closed evidence"
    manifest_row "unsupported-hardware-fail-closed" "TODO" "" "Attach unsupported hardware fail-closed evidence"
    manifest_row "logs" "evidence" "evidence/logs.txt" "summary log captured"
    manifest_row "combined-sensor-signal" "n/a" "" "closedBagCoverage=insufficient; combined signal evidence not selected"
    manifest_row "provider-update-or-restart" "n/a" "" "provider restart/update not exercised in this proof attempt"
} >"$OUTPUT_DIR/provider-manifest.tsv"

cat >"$OUTPUT_DIR/README.md" <<EOF
# Powermetrics Provider Proof Attempt

This artifact was produced by:

\`\`\`sh
scripts/temperature-provider-powermetrics-proof.sh --output-dir $(printf '%q' "$OUTPUT_DIR")
\`\`\`

This run is non-mutating and uses no promptable authorization path. It is an
honest proof attempt, not a completed #25 provider proof.

Current outcome:

- Permission state: \`$permission_state\`
- Helper/root-equivalent sampling available: \`$helper_owned\`
- Numeric temperature output observed: \`$numeric_temperature_observed\`
- Numeric cutoff source proven: \`$numeric_cutoff_source\`
- Provider proof ready: \`false\`
- Result: \`$result\`

Run the structural verifier before attaching completed proof:

\`\`\`sh
scripts/temperature-provider-proof-verify.sh --manifest "$OUTPUT_DIR/provider-manifest.tsv"
\`\`\`

Verifier failure is expected until TODO rows are replaced with real helper/root
freshness, cadence, closed-bag coverage, and fail-closed evidence.
EOF

echo "Powermetrics provider proof attempt written to $OUTPUT_DIR"
echo "Verifier is expected to fail until TODO rows are replaced with real evidence."
