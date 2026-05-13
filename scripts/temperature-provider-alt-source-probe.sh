#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/temperature-provider-alt-source-probe.sh ..." >&2
    exit 2
fi
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/temperature-provider-alt-source-probe.sh --output-dir DIR [--case-id ID]
   or: scripts/temperature-provider-alt-source-probe.sh DIR

Captures a non-mutating #25 probe for helper-owned temperature sources beyond
powermetrics. It inventories local SMC, SMC sensor dispatcher, PMU temperature
sensor, NVMe temperature sensor, die temperature, HID service/dump, and
IOReport-style surfaces without sudo and without selecting a production provider.

The package is evidence only. Provider proof remains false until a helper-owned
source proves numeric output, freshness, cadence, timeout, closed-bag coverage,
and fail-closed behavior.
USAGE
}

OUTPUT_DIR=""
CASE_ID="apple-silicon-alt-temperature-source-probe"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --output-dir)
            [[ "$#" -ge 2 ]] || { echo "--output-dir requires a value" >&2; exit 64; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --case-id)
            [[ "$#" -ge 2 ]] || { echo "--case-id requires a value" >&2; exit 64; }
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
if [[ -L "$OUTPUT_DIR" ]]; then
    echo "Output path must not be a symlink: $OUTPUT_DIR" >&2
    exit 73
fi
if [[ -e "$OUTPUT_DIR" && -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    echo "Output directory is not empty: $OUTPUT_DIR" >&2
    exit 73
fi

TIMEOUT_SECONDS="${CLAWSHELL_TEMPERATURE_ALT_SOURCE_TIMEOUT_SECONDS:-2}"
MAX_LINES="${CLAWSHELL_TEMPERATURE_ALT_SOURCE_MAX_LINES:-200}"

require_positive_integer() {
    local name="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
        echo "$name must be a positive integer" >&2
        exit 64
    fi
}

require_positive_integer "CLAWSHELL_TEMPERATURE_ALT_SOURCE_TIMEOUT_SECONDS" "$TIMEOUT_SECONDS"
require_positive_integer "CLAWSHELL_TEMPERATURE_ALT_SOURCE_MAX_LINES" "$MAX_LINES"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
EVIDENCE_DIR="$OUTPUT_DIR/evidence"
mkdir -p "$EVIDENCE_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
        cleanup_child() {
            if [[ -n "$child_pid" ]]; then
                kill -TERM -- "-$child_pid" 2>/dev/null || kill "$child_pid" 2>/dev/null || true
                sleep 0.1
                if kill -0 "$child_pid" 2>/dev/null; then
                    kill -KILL -- "-$child_pid" 2>/dev/null || kill -KILL "$child_pid" 2>/dev/null || true
                fi
                wait "$child_pid" 2>/dev/null || true
            fi
        }
        trap 'cleanup_child; exit 124' TERM
        if command -v perl >/dev/null 2>&1; then
            perl -e 'setpgrp(0, 0) or die "setpgrp failed: $!"; exec @ARGV or die "exec failed: $!"' "${cmd[@]}" &
        else
            "${cmd[@]}" &
        fi
        child_pid=$!
        wait "$child_pid"
    ) >"$out_file" 2>&1 &
    pid=$!

    (
        sleep "$limit_seconds"
        if kill -0 "$pid" 2>/dev/null; then
            : >"$timeout_marker"
            kill "$pid" 2>/dev/null || true
            sleep 1
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

manifest_row() {
    local check_id="$1"
    local status="$2"
    local path="$3"
    local note="$4"
    printf '%s\t%s\t%s\t%s\n' "$check_id" "$status" "$path" "$note"
}

IOREG_BIN="${CLAWSHELL_TEMPERATURE_ALT_SOURCE_IOREG:-$(command -v ioreg 2>/dev/null || true)}"
if [[ -z "$IOREG_BIN" ]]; then
    IOREG_BIN="/usr/sbin/ioreg"
fi
HIDUTIL_BIN="${CLAWSHELL_TEMPERATURE_ALT_SOURCE_HIDUTIL:-$(command -v hidutil 2>/dev/null || true)}"
CLANG_BIN="${CLAWSHELL_TEMPERATURE_ALT_SOURCE_CLANG:-$(command -v clang 2>/dev/null || true)}"
IOHID_PROBE_BIN="${CLAWSHELL_TEMPERATURE_ALT_SOURCE_IOHID_PROBE:-}"

capture "smc-endpoint-inventory" "$TIMEOUT_SECONDS" "$IOREG_BIN" -r -c AppleSMCKeysEndpoint -l
capture "smc-temp-sensor-node-inventory" "$TIMEOUT_SECONDS" "$IOREG_BIN" -r -n smctempsensor0 -l
capture "smc-sensor-dispatcher-inventory" "$TIMEOUT_SECONDS" "$IOREG_BIN" -r -c AppleSMCSensorDispatcher -l
capture "pmu-temperature-sensor-inventory" "$TIMEOUT_SECONDS" "$IOREG_BIN" -r -c AppleARMPMUTempSensor -l
capture "nvme-temperature-sensor-inventory" "$TIMEOUT_SECONDS" "$IOREG_BIN" -r -c AppleEmbeddedNVMeTemperatureSensor -l
capture "die-temperature-controller-inventory" "$TIMEOUT_SECONDS" "$IOREG_BIN" -r -c AppleDieTempController -l
if [[ -n "$HIDUTIL_BIN" ]]; then
    capture "hidutil-service-inventory" "$TIMEOUT_SECONDS" "$HIDUTIL_BIN" list
    capture "hidutil-temperature-service-ndjson" "$TIMEOUT_SECONDS" "$HIDUTIL_BIN" list --ndjson --matching '{"PrimaryUsagePage":65280,"PrimaryUsage":5}'
    # shellcheck disable=SC2016
    capture "hidutil-temperature-service-dump" "$TIMEOUT_SECONDS" bash -c '
set -euo pipefail
"$1" dump services -f text 2>/dev/null |
awk -v max_lines="$2" '"'"'
    tolower($0) !~ /apple(arm)?pmu|appleembeddednvmetemperaturesensor|applesmckeysendpoint|nand.*temp|pmu t(dev|die)|temperature|thermal|temp|ioclass|product|primaryusage|primaryusagepage|reportinterval/ {
        next
    }
    {
        if (count < max_lines) {
            print
            count++
        }
    }
'"'"'
' _ "$HIDUTIL_BIN" "$MAX_LINES"
else
    capture "hidutil-service-inventory" "$TIMEOUT_SECONDS" bash -c 'echo "hidutil unavailable"; exit 127'
    capture "hidutil-temperature-service-ndjson" "$TIMEOUT_SECONDS" bash -c 'echo "hidutil unavailable"; exit 127'
    capture "hidutil-temperature-service-dump" "$TIMEOUT_SECONDS" bash -c 'echo "hidutil unavailable"; exit 127'
fi
if [[ -n "$IOHID_PROBE_BIN" ]]; then
    capture "iohid-service-probe-build" "$TIMEOUT_SECONDS" bash -c 'echo "using configured IOHID probe: $1"' _ "$IOHID_PROBE_BIN"
    capture "iohid-temperature-service-properties" "$TIMEOUT_SECONDS" "$IOHID_PROBE_BIN" "$MAX_LINES"
elif [[ -n "$CLANG_BIN" && "$(uname -s)" == "Darwin" && -r "$SCRIPT_DIR/temperature-provider-iohid-service-probe.c" ]]; then
    capture "iohid-service-probe-build" "$TIMEOUT_SECONDS" "$CLANG_BIN" -x c -framework IOKit -framework CoreFoundation -o "$OUTPUT_DIR/iohid-service-probe" "$SCRIPT_DIR/temperature-provider-iohid-service-probe.c"
    if grep -q '^exitCode=0$' "$EVIDENCE_DIR/iohid-service-probe-build.status" && [[ -x "$OUTPUT_DIR/iohid-service-probe" ]]; then
        capture "iohid-temperature-service-properties" "$TIMEOUT_SECONDS" "$OUTPUT_DIR/iohid-service-probe" "$MAX_LINES"
    else
        capture "iohid-temperature-service-properties" "$TIMEOUT_SECONDS" bash -c 'echo "IOHID service probe build failed"; exit 127'
    fi
else
    capture "iohid-service-probe-build" "$TIMEOUT_SECONDS" bash -c 'echo "IOHID service probe build unavailable"; exit 127'
    capture "iohid-temperature-service-properties" "$TIMEOUT_SECONDS" bash -c 'echo "IOHID service probe unavailable"; exit 127'
fi
# shellcheck disable=SC2016
capture "ioreport-temperature-legend-inventory" "$TIMEOUT_SECONDS" bash -c '
set -euo pipefail
"$1" -l -w0 2>/dev/null |
grep -Ei '"'"'^[[:space:]|]*\+-o|AppleSmartBattery|IOReport(GroupName|SubGroupName|Channels)|temperature|thermal|temp|die'"'"' |
awk -v max_lines="$2" '"'"'
    {
        print
        count++
        if (count >= max_lines) {
            exit
        }
    }
'"'"'
' _ "$IOREG_BIN" "$MAX_LINES"

smc_endpoint_present=false
smc_temp_sensor_node_present=false
smc_sensor_dispatcher_present=false
smc_sensor_dispatcher_user_client_present=false
smc_sensor_dispatcher_thermalmonitord_client_present=false
pmu_temp_sensor_present=false
nvme_temp_sensor_present=false
die_temp_controller_present=false
hidutil_available=false
hid_pmu_temperature_inventory_present=false
hid_pmu_temperature_service_count=0
hid_nvme_temperature_inventory_present=false
hid_temperature_service_dump_present=false
iohid_probe_available=false
iohid_temperature_service_count=0
iohid_value_property_count=0
iohid_numeric_value_property_count=0
ioreport_temperature_legend_present=false
numeric_temperature_observed=false
numeric_candidate_count=0
numeric_raw_candidate_count=0
numeric_rejected_battery_context_count=0
numeric_rejection_reason="none"

numeric_candidate_pattern='(^|[^[:alnum:]_-])([[:alnum:]]*temperature|temp)[^[:alnum:]_:=.-]*(=|:)[[:space:]]*-?[0-9]+([.][0-9]+)?([[:blank:]]*(°C|celsius|degrees?[[:blank:]]*C|C\>))?'

if grep -Fq 'AppleSMCKeysEndpoint' "$EVIDENCE_DIR/smc-endpoint-inventory.txt"; then
    smc_endpoint_present=true
fi
if grep -Fq 'smctempsensor0' "$EVIDENCE_DIR/smc-temp-sensor-node-inventory.txt"; then
    smc_temp_sensor_node_present=true
fi
if grep -Fq 'AppleSMCSensorDispatcher' "$EVIDENCE_DIR/smc-sensor-dispatcher-inventory.txt" "$EVIDENCE_DIR/smc-temp-sensor-node-inventory.txt"; then
    smc_sensor_dispatcher_present=true
fi
if grep -Fq 'AppleSMCSensorDispatcherUserClient' "$EVIDENCE_DIR/smc-sensor-dispatcher-inventory.txt" "$EVIDENCE_DIR/smc-temp-sensor-node-inventory.txt"; then
    smc_sensor_dispatcher_user_client_present=true
fi
if grep -Fq 'thermalmonitord' "$EVIDENCE_DIR/smc-sensor-dispatcher-inventory.txt" "$EVIDENCE_DIR/smc-temp-sensor-node-inventory.txt"; then
    smc_sensor_dispatcher_thermalmonitord_client_present=true
fi
if grep -Fq 'AppleARMPMUTempSensor' "$EVIDENCE_DIR/pmu-temperature-sensor-inventory.txt"; then
    pmu_temp_sensor_present=true
fi
if grep -Fq 'AppleEmbeddedNVMeTemperatureSensor' "$EVIDENCE_DIR/nvme-temperature-sensor-inventory.txt"; then
    nvme_temp_sensor_present=true
fi
if grep -Fq 'AppleDieTempController' "$EVIDENCE_DIR/die-temperature-controller-inventory.txt"; then
    die_temp_controller_present=true
fi
if [[ -n "$HIDUTIL_BIN" ]]; then
    hidutil_available=true
fi
if grep -Eiq 'AppleSMCKeysEndpoint[[:space:]]+PMU t(dev|die)[[:alnum:]]*' "$EVIDENCE_DIR/hidutil-service-inventory.txt"; then
    hid_pmu_temperature_inventory_present=true
fi
hid_pmu_temperature_service_count="$(
    { grep -Ehi '"Product":"PMU t(dev|die)[[:alnum:]]*' \
        "$EVIDENCE_DIR/hidutil-temperature-service-ndjson.txt" 2>/dev/null || true; } |
        wc -l |
        tr -d '[:space:]'
)"
if grep -Eiq 'AppleEmbeddedNVMeTemperatureSensor|NAND.*temp' "$EVIDENCE_DIR/hidutil-service-inventory.txt" "$EVIDENCE_DIR/hidutil-temperature-service-ndjson.txt"; then
    hid_nvme_temperature_inventory_present=true
fi
if grep -Eiq 'AppleARMPMUTempSensor|AppleEmbeddedNVMeTemperatureSensor|PMU t(dev|die)|NAND.*temp' "$EVIDENCE_DIR/hidutil-temperature-service-dump.txt"; then
    hid_temperature_service_dump_present=true
fi
value_for_key() {
    local key="$1"
    local file="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}
if grep -q '^iohidProbeFormat=iohid-service-property-probe-v1$' "$EVIDENCE_DIR/iohid-temperature-service-properties.txt"; then
    iohid_probe_available=true
    iohid_temperature_service_count="$(value_for_key matchedTemperatureServices "$EVIDENCE_DIR/iohid-temperature-service-properties.txt")"
    iohid_value_property_count="$(value_for_key valuePropertyCount "$EVIDENCE_DIR/iohid-temperature-service-properties.txt")"
    iohid_numeric_value_property_count="$(value_for_key numericValuePropertyCount "$EVIDENCE_DIR/iohid-temperature-service-properties.txt")"
    iohid_temperature_service_count="${iohid_temperature_service_count:-0}"
    iohid_value_property_count="${iohid_value_property_count:-0}"
    iohid_numeric_value_property_count="${iohid_numeric_value_property_count:-0}"
    if ! [[ "$iohid_temperature_service_count" =~ ^[0-9]+$ ]]; then
        iohid_temperature_service_count=0
    fi
    if ! [[ "$iohid_value_property_count" =~ ^[0-9]+$ ]]; then
        iohid_value_property_count=0
    fi
    if ! [[ "$iohid_numeric_value_property_count" =~ ^[0-9]+$ ]]; then
        iohid_numeric_value_property_count=0
    fi
fi
if grep -Eiq 'temperature|thermal|temp|die' "$EVIDENCE_DIR/ioreport-temperature-legend-inventory.txt"; then
    ioreport_temperature_legend_present=true
fi
raw_candidates_tmp="$EVIDENCE_DIR/numeric-temperature-candidates.raw.tmp"
accepted_candidates_tmp="$EVIDENCE_DIR/numeric-temperature-candidates.accepted.tmp"
rejected_candidates_tmp="$EVIDENCE_DIR/rejected-temperature-candidates.tmp"
: >"$raw_candidates_tmp"
: >"$accepted_candidates_tmp"
: >"$rejected_candidates_tmp"

classify_tree_candidates() {
    local source_file="$1"
    awk -v source_file="$source_file" \
        -v raw_file="$raw_candidates_tmp" \
        -v accepted_file="$accepted_candidates_tmp" \
        -v rejected_file="$rejected_candidates_tmp" '
    function is_candidate(line) {
        return line ~ /(^|[^[:alnum:]_-])([[:alnum:]]*[Tt]emperature|[Tt]emp)[^[:alnum:]_:=.-]*(=|:)[[:space:]]*-?[0-9]+([.][0-9]+)?/
    }
    BEGIN {
        battery_depth = -1
    }
    /^[ \t|]*\+-o[ \t]+/ {
        prefix = $0
        sub(/\+-o.*/, "", prefix)
        depth = length(prefix)
        is_battery_node = ($0 ~ /\+-o[ \t]+AppleSmartBattery(Manager)?([ \t<]|$)/)
        if (battery_depth >= 0 && depth <= battery_depth && !is_battery_node) {
            battery_depth = -1
        }
        if (is_battery_node) {
            battery_depth = depth
        }
    }
    {
        if (is_candidate($0) && length($0) <= 500) {
            candidate = source_file ":" NR ":" $0
            print candidate >> raw_file
            if (battery_depth >= 0) {
                print candidate >> rejected_file
            } else {
                print candidate >> accepted_file
            }
        }
    }
' "$source_file"
}

classify_tree_candidates "$EVIDENCE_DIR/smc-endpoint-inventory.txt"
classify_tree_candidates "$EVIDENCE_DIR/smc-temp-sensor-node-inventory.txt"
classify_tree_candidates "$EVIDENCE_DIR/smc-sensor-dispatcher-inventory.txt"
classify_tree_candidates "$EVIDENCE_DIR/ioreport-temperature-legend-inventory.txt"

for candidate_file in \
    "$EVIDENCE_DIR/pmu-temperature-sensor-inventory.txt" \
    "$EVIDENCE_DIR/nvme-temperature-sensor-inventory.txt" \
    "$EVIDENCE_DIR/die-temperature-controller-inventory.txt"
do
    grep -HniE "$numeric_candidate_pattern" "$candidate_file" |
        grep -Ev 'IOReportLegend|IOReportChannels' |
        awk 'length($0) <= 500' \
        >>"$accepted_candidates_tmp" || true
done
cat "$accepted_candidates_tmp" >>"$raw_candidates_tmp"
head -n "$MAX_LINES" "$accepted_candidates_tmp" >"$EVIDENCE_DIR/numeric-temperature-candidates.txt"
head -n "$MAX_LINES" "$rejected_candidates_tmp" >"$EVIDENCE_DIR/rejected-temperature-candidates.txt"
rm -f "$raw_candidates_tmp" "$accepted_candidates_tmp" "$rejected_candidates_tmp"

numeric_candidate_count="$(wc -l <"$EVIDENCE_DIR/numeric-temperature-candidates.txt" | tr -d '[:space:]')"
numeric_raw_candidate_count=$(( numeric_candidate_count + $(wc -l <"$EVIDENCE_DIR/rejected-temperature-candidates.txt" | tr -d '[:space:]') ))
numeric_rejected_battery_context_count="$(wc -l <"$EVIDENCE_DIR/rejected-temperature-candidates.txt" | tr -d '[:space:]')"
if [[ "$numeric_candidate_count" -gt 0 ]]; then
    numeric_temperature_observed=true
fi
if [[ "$numeric_raw_candidate_count" -gt 0 && "$numeric_candidate_count" -eq 0 && "$numeric_rejected_battery_context_count" -gt 0 ]]; then
    numeric_rejection_reason="ioreg-smc-battery-context-only"
fi
{
    echo "command=classify numeric temperature candidate pattern evidence/*.txt excluding IOReportLegend/IOReportChannels metadata, long context lines, and AppleSmartBattery context"
    echo "exitCode=0"
    echo "numericCandidatePattern=$numeric_candidate_pattern"
    echo "numericCandidateMaxLines=$MAX_LINES"
    echo "numericCandidateCount=$numeric_candidate_count"
    echo "numericRawCandidateCount=$numeric_raw_candidate_count"
    echo "numericRejectedBatteryContextCount=$numeric_rejected_battery_context_count"
    echo "numericRejectionReason=$numeric_rejection_reason"
} >"$EVIDENCE_DIR/numeric-temperature-candidates.status"

candidate_surface_available=false
if [[ "$smc_endpoint_present" == true || "$smc_temp_sensor_node_present" == true || "$smc_sensor_dispatcher_present" == true || "$pmu_temp_sensor_present" == true || "$nvme_temp_sensor_present" == true || "$die_temp_controller_present" == true || "$hid_pmu_temperature_inventory_present" == true || "$hid_nvme_temperature_inventory_present" == true || "$hid_temperature_service_dump_present" == true || "$iohid_temperature_service_count" -gt 0 || "$ioreport_temperature_legend_present" == true ]]; then
    candidate_surface_available=true
fi

cat >"$OUTPUT_DIR/validation-config.txt" <<EOF
evidenceFormat=temperature-alt-source-probe-v4
metadataRedacted=true
caseId=$CASE_ID
capturedAtUtc=$(now_utc)
timeoutSeconds=$TIMEOUT_SECONDS
maxInventoryLines=$MAX_LINES
ioregPath=$IOREG_BIN
hidutilPath=${HIDUTIL_BIN:-unavailable}
smcEndpointPresent=$smc_endpoint_present
smcTempSensorNodePresent=$smc_temp_sensor_node_present
smcSensorDispatcherPresent=$smc_sensor_dispatcher_present
smcSensorDispatcherUserClientPresent=$smc_sensor_dispatcher_user_client_present
smcSensorDispatcherThermalmonitordClientPresent=$smc_sensor_dispatcher_thermalmonitord_client_present
pmuTempSensorPresent=$pmu_temp_sensor_present
nvmeTempSensorPresent=$nvme_temp_sensor_present
dieTempControllerPresent=$die_temp_controller_present
hidutilAvailable=$hidutil_available
hidPmuTemperatureInventoryPresent=$hid_pmu_temperature_inventory_present
hidPmuTemperatureServiceCount=$hid_pmu_temperature_service_count
hidNvmeTemperatureInventoryPresent=$hid_nvme_temperature_inventory_present
hidTemperatureServiceDumpPresent=$hid_temperature_service_dump_present
iohidProbeAvailable=$iohid_probe_available
iohidTemperatureServiceCount=$iohid_temperature_service_count
iohidValuePropertyCount=$iohid_value_property_count
iohidNumericValuePropertyCount=$iohid_numeric_value_property_count
ioreportTemperatureLegendPresent=$ioreport_temperature_legend_present
candidateSurfaceAvailable=$candidate_surface_available
helperOwned=false
numericTemperatureObserved=$numeric_temperature_observed
numericTemperatureCandidateCount=$numeric_candidate_count
numericTemperatureRawCandidateCount=$numeric_raw_candidate_count
numericTemperatureRejectedBatteryContextCount=$numeric_rejected_battery_context_count
numericTemperatureRejectionReason=$numeric_rejection_reason
numericCutoffSource=false
freshnessProven=false
activeCadenceProven=false
idleCadenceProven=false
closedBagCoverageProven=false
providerProofReady=false
EOF

cat >"$OUTPUT_DIR/source-probe-manifest.tsv" <<EOF
checkId	status	evidencePath	note
$(manifest_row "smc-endpoint-inventory" "evidence" "evidence/smc-endpoint-inventory.txt" "SMC endpoint inventory captured without sudo")
$(manifest_row "smc-temp-sensor-node-inventory" "evidence" "evidence/smc-temp-sensor-node-inventory.txt" "SMC temp-sensor node inventory captured without sudo")
$(manifest_row "smc-sensor-dispatcher-inventory" "evidence" "evidence/smc-sensor-dispatcher-inventory.txt" "AppleSMCSensorDispatcher inventory captured without sudo; user-client presence is not a scalar reading")
$(manifest_row "pmu-temperature-sensor-inventory" "evidence" "evidence/pmu-temperature-sensor-inventory.txt" "PMU temperature sensor inventory captured without sudo")
$(manifest_row "nvme-temperature-sensor-inventory" "evidence" "evidence/nvme-temperature-sensor-inventory.txt" "NVMe temperature sensor inventory captured without sudo; NAND temp names are inventory, not readings")
$(manifest_row "die-temperature-controller-inventory" "evidence" "evidence/die-temperature-controller-inventory.txt" "Die temperature controller inventory captured without sudo")
$(manifest_row "hidutil-service-inventory" "evidence" "evidence/hidutil-service-inventory.txt" "HID service inventory captured without sudo; PMU tdev/tdie names are inventory, not readings")
$(manifest_row "hidutil-temperature-service-ndjson" "evidence" "evidence/hidutil-temperature-service-ndjson.txt" "HID primary-usage temperature services captured as NDJSON inventory, not readings")
$(manifest_row "hidutil-temperature-service-dump" "evidence" "evidence/hidutil-temperature-service-dump.txt" "Bounded HID services dump captured for PMU/NVMe temperature-service metadata only")
$(manifest_row "iohid-service-probe-build" "evidence" "evidence/iohid-service-probe-build.txt" "Native IOHID probe compile/configuration evidence")
$(manifest_row "iohid-temperature-service-properties" "evidence" "evidence/iohid-temperature-service-properties.txt" "Native IOHIDServiceClient property probe for common current-value keys; discovery only")
$(manifest_row "ioreport-temperature-legend-inventory" "evidence" "evidence/ioreport-temperature-legend-inventory.txt" "IOReport-style temperature/thermal legend inventory captured without sudo")
$(manifest_row "numeric-temperature-candidates" "evidence" "evidence/numeric-temperature-candidates.txt" "Bounded candidate lines for later provider review; not promoted to cutoff proof")
$(manifest_row "rejected-temperature-candidates" "evidence" "evidence/rejected-temperature-candidates.txt" "Battery-context temperature lines rejected for production cutoff review")
$(manifest_row "numeric-cutoff-source" "TODO" "" "Probe does not prove helper-owned numeric cutoff output")
$(manifest_row "freshness-cadence-coverage" "TODO" "" "Probe does not prove freshness, active/idle cadence, or closed-bag coverage")
EOF

cat >"$OUTPUT_DIR/README.md" <<EOF
# Temperature Provider Alternate Source Probe

This package inventories non-powermetrics SMC, SMC sensor dispatcher, PMU
temperature sensor, NVMe temperature sensor, die temperature controller, HID
service/dump, native IOHID service properties, and IOReport-style local
surfaces for #25.

It is non-mutating, does not use sudo, and does not select a production Bag Mode
temperature provider. A usable provider still needs helper-owned numeric output,
freshness, active/idle cadence, timeout behavior, closed-bag coverage, and
fail-closed evidence.

Key fields are in \`validation-config.txt\`.
EOF

echo "Temperature provider alternate source probe written to $OUTPUT_DIR"
echo "This is discovery evidence only; providerProofReady remains false."
