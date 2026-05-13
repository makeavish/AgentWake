#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/temperature-provider-proof-verify.sh ..." >&2
    exit 2
fi
set -euo pipefail

MANIFEST_FILE=""
SEEN_CHECK_IDS=("__sentinel__")
case_errors=0
CONFIG_PROVIDER_SOURCE=""
CONFIG_CPU=""
CONFIG_HARDWARE_CLASS=""
CONFIG_HELPER_OWNED=""
CONFIG_PROCESSINFO_SUPPLEMENTAL_ONLY=""
CONFIG_NUMERIC_CUTOFF_SOURCE=""
CONFIG_NO_USER_VISIBLE_PROMPTS=""
CONFIG_FRESHNESS_MAX_AGE_SECONDS=""
CONFIG_ACTIVE_CADENCE_SECONDS=""
CONFIG_IDLE_CADENCE_SECONDS=""
CONFIG_TIMEOUT_SECONDS=""
CONFIG_CLOSED_BAG_COVERAGE=""
CONFIG_FAIL_CLOSED_CONTRACT=""
COMBINED_SENSOR_STATUS=""
CONFIG_RESULT=""

usage() {
    cat <<'EOF'
Usage: scripts/temperature-provider-proof-verify.sh --manifest PATH

Checks #25 helper-owned Bag Mode temperature-provider proof evidence for
structure and internal consistency. This verifier does not select a provider,
run privileged sampling, or prove thermal safety; it only fails incomplete or
placeholder evidence before it is attached to #25.

The manifest must be a TSV file with this header:

checkId	status	evidencePath	note
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --manifest)
            if [[ "$#" -lt 2 ]]; then
                echo "--manifest requires a value" >&2
                exit 2
            fi
            MANIFEST_FILE="$2"
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

if [[ -z "$MANIFEST_FILE" ]]; then
    echo "Provide --manifest." >&2
    usage >&2
    exit 2
fi

if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "Manifest is not a file: $MANIFEST_FILE" >&2
    exit 2
fi

MANIFEST_DIR="$(cd "$(dirname "$MANIFEST_FILE")" && pwd)"
CONFIG_FILE="$MANIFEST_DIR/validation-config.txt"
MANUAL_FILE="$MANIFEST_DIR/manual-result.md"

required_check_ids() {
    cat <<'EOF'
provider-command-or-api
helper-ownership-context
numeric-temperature-output
freshness-samples
active-cadence-samples
idle-cadence-samples
timeout-enforcement
timeout-fail-closed
permission-behavior
no-user-visible-prompts
closed-bag-coverage-analysis
processinfo-supplemental-signal
safety-contract-tests
unavailable-fail-closed
stale-fail-closed
permission-denied-fail-closed
parse-failed-fail-closed
helper-crashed-fail-closed
unsupported-hardware-fail-closed
logs
EOF
}

optional_check_ids() {
    cat <<'EOF'
combined-sensor-signal
provider-update-or-restart
EOF
}

trim_value() {
    printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

record_error() {
    local context="$1"
    local message="$2"
    printf 'ERROR [%s] %s\n' "$context" "$message" >&2
    case_errors=$((case_errors + 1))
}

is_unfilled_value() {
    local value
    value="$(trim_value "$1")"

    [[ -z "$value" ]] && return 0
    [[ "$value" == "TODO" ]] && return 0
    [[ "$value" == "TBD" ]] && return 0
    [[ "$value" == *"<"* && "$value" == *">"* ]] && return 0
    [[ "$value" == *" | "* ]] && return 0
    return 1
}

is_choice_value() {
    local value="$1"
    shift
    for choice in "$@"; do
        if [[ "$value" == "$choice" ]]; then
            return 0
        fi
    done
    return 1
}

has_placeholder_content() {
    local file="$1"
    grep -Eiq '(^|[[:space:]])(TODO|TBD)([[:space:]]|$)|<(paste output|paste here|output|TODO|TBD)[^>]*>|paste[[:space:]-]*(output|here)|placeholder evidence|evidence for [A-Za-z0-9_-]+' "$file"
}

directory_has_placeholder_content() {
    local dir="$1"
    local evidence_file
    while IFS= read -r evidence_file; do
        if has_placeholder_content "$evidence_file"; then
            return 0
        fi
    done < <(find "$dir" -type f -size +0c -print)
    return 1
}

path_has_symlink_component() {
    local relative_path="$1"
    local current="$MANIFEST_DIR"
    local component
    local components
    IFS='/' read -r -a components <<<"$relative_path"
    for component in "${components[@]}"; do
        [[ -z "$component" || "$component" == "." ]] && continue
        current="$current/$component"
        if [[ -L "$current" ]]; then
            return 0
        fi
    done
    return 1
}

path_has_parent_segment() {
    local relative_path="$1"
    local component
    local components
    IFS='/' read -r -a components <<<"$relative_path"
    for component in "${components[@]}"; do
        if [[ "$component" == ".." ]]; then
            return 0
        fi
    done
    return 1
}

is_known_id() {
    local check_id="$1"
    required_check_ids | grep -qx "$check_id" && return 0
    optional_check_ids | grep -qx "$check_id" && return 0
    return 1
}

is_required_id() {
    local check_id="$1"
    required_check_ids | grep -qx "$check_id"
}

has_seen_id() {
    local check_id="$1"
    local seen
    for seen in "${SEEN_CHECK_IDS[@]}"; do
        [[ "$seen" == "$check_id" ]] && return 0
    done
    return 1
}

value_for_key() {
    local key="$1"
    local file="$2"
    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); found = 1 } END { if (!found) exit 1 }' "$file"
}

field_value() {
    local label="$1"
    local file="$2"
    awk -v label="$label" '
        index($0, "- " label ":") == 1 {
            sub("^- " label ": *", "")
            print
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$file"
}

require_file() {
    local context="$1"
    local file="$2"
    if [[ ! -f "$file" ]]; then
        record_error "$context" "missing file: $file"
    elif [[ ! -s "$file" ]]; then
        record_error "$context" "empty file: $file"
    fi
}

check_required_field() {
    local label="$1"
    local value

    if ! value="$(field_value "$label" "$MANUAL_FILE" 2>/dev/null)"; then
        record_error "manual-result.md" "missing field: $label"
        return
    fi

    if is_unfilled_value "$value"; then
        record_error "manual-result.md" "placeholder value for: $label"
    fi
}

check_choice_field() {
    local label="$1"
    shift
    local value

    if ! value="$(field_value "$label" "$MANUAL_FILE" 2>/dev/null)"; then
        record_error "manual-result.md" "missing field: $label"
        return
    fi

    value="$(trim_value "$value")"
    if ! is_choice_value "$value" "$@"; then
        record_error "manual-result.md" "field '$label' must be one of: $*"
    fi
}

numeric_field_value() {
    local label="$1"
    local value
    value="$(field_value "$label" "$MANUAL_FILE" 2>/dev/null || true)"
    value="$(trim_value "$value")"
    printf '%s' "$value"
}

is_nonnegative_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ && "$1" -gt 0 ]]
}

verify_config() {
    require_file "validation-config.txt" "$CONFIG_FILE"
    [[ -f "$CONFIG_FILE" ]] || return

    local format metadata_redacted macos_version cpu
    format="$(value_for_key evidenceFormat "$CONFIG_FILE" 2>/dev/null || true)"
    metadata_redacted="$(value_for_key metadataRedacted "$CONFIG_FILE" 2>/dev/null || true)"
    macos_version="$(value_for_key macOSVersion "$CONFIG_FILE" 2>/dev/null || true)"
    cpu="$(value_for_key cpu "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_CPU="$cpu"
    CONFIG_HARDWARE_CLASS="$(value_for_key hardwareClass "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_PROVIDER_SOURCE="$(value_for_key providerSource "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_HELPER_OWNED="$(value_for_key helperOwned "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_PROCESSINFO_SUPPLEMENTAL_ONLY="$(value_for_key processInfoSupplementalOnly "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_NUMERIC_CUTOFF_SOURCE="$(value_for_key numericCutoffSource "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_NO_USER_VISIBLE_PROMPTS="$(value_for_key noUserVisiblePrompts "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_FRESHNESS_MAX_AGE_SECONDS="$(value_for_key freshnessMaxAgeSeconds "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_ACTIVE_CADENCE_SECONDS="$(value_for_key activeCadenceSeconds "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_IDLE_CADENCE_SECONDS="$(value_for_key idleCadenceSeconds "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_TIMEOUT_SECONDS="$(value_for_key timeoutSeconds "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_CLOSED_BAG_COVERAGE="$(value_for_key closedBagCoverage "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_FAIL_CLOSED_CONTRACT="$(value_for_key failClosedContract "$CONFIG_FILE" 2>/dev/null || true)"
    CONFIG_RESULT="$(value_for_key result "$CONFIG_FILE" 2>/dev/null || true)"

    if [[ "$format" != "temperature-provider-proof-v1" ]]; then
        record_error "validation-config.txt" "evidenceFormat must be temperature-provider-proof-v1"
    fi
    if [[ "$metadata_redacted" != "true" ]]; then
        record_error "validation-config.txt" "metadataRedacted must be true"
    fi
    if [[ "$macos_version" =~ ^(macOS[[:space:]]+)?([0-9]+)(\.[0-9]+)*\+?$ ]]; then
        if [[ "${BASH_REMATCH[2]}" -lt 13 ]]; then
            record_error "validation-config.txt" "macOSVersion must be 13 or newer"
        fi
    else
        record_error "validation-config.txt" "macOSVersion must look like a macOS version, for example 15.0"
    fi
    if ! is_choice_value "$cpu" "Apple Silicon" "Intel"; then
        record_error "validation-config.txt" "cpu must be Apple Silicon or Intel"
    fi
    if ! is_choice_value "$CONFIG_HARDWARE_CLASS" "MacBook" "desktop" "unknown"; then
        record_error "validation-config.txt" "hardwareClass must be MacBook, desktop, or unknown"
    fi
    if ! is_choice_value "$CONFIG_PROVIDER_SOURCE" "powermetrics" "ioreg-smc" "ioreg-pmu" "thermal-levels" "SMC" "IOReport" "other"; then
        record_error "validation-config.txt" "providerSource must be powermetrics, ioreg-smc, ioreg-pmu, thermal-levels, SMC, IOReport, or other"
    fi
    if [[ "$CONFIG_HELPER_OWNED" != "true" ]]; then
        record_error "validation-config.txt" "helperOwned must be true for #25 evidence"
    fi
    if [[ "$CONFIG_PROCESSINFO_SUPPLEMENTAL_ONLY" != "true" ]]; then
        record_error "validation-config.txt" "processInfoSupplementalOnly must be true"
    fi
    if [[ "$CONFIG_NUMERIC_CUTOFF_SOURCE" != "true" ]]; then
        record_error "validation-config.txt" "numericCutoffSource must be true"
    fi
    if [[ "$CONFIG_NO_USER_VISIBLE_PROMPTS" != "true" ]]; then
        record_error "validation-config.txt" "noUserVisiblePrompts must be true"
    fi
    if ! is_positive_integer "$CONFIG_FRESHNESS_MAX_AGE_SECONDS" || [[ "$CONFIG_FRESHNESS_MAX_AGE_SECONDS" -gt 10 ]]; then
        record_error "validation-config.txt" "freshnessMaxAgeSeconds must be an integer no greater than 10"
    fi
    if [[ "$CONFIG_ACTIVE_CADENCE_SECONDS" != "5" ]]; then
        record_error "validation-config.txt" "activeCadenceSeconds must be 5"
    fi
    if [[ "$CONFIG_IDLE_CADENCE_SECONDS" != "30" ]]; then
        record_error "validation-config.txt" "idleCadenceSeconds must be 30"
    fi
    if [[ "$CONFIG_TIMEOUT_SECONDS" != "1" ]]; then
        record_error "validation-config.txt" "timeoutSeconds must be 1"
    fi
    if ! is_choice_value "$CONFIG_CLOSED_BAG_COVERAGE" "accepted" "requires-combined-signals" "insufficient"; then
        record_error "validation-config.txt" "closedBagCoverage must be accepted, requires-combined-signals, or insufficient"
    fi
    if [[ "$CONFIG_RESULT" == "pass" && "$CONFIG_CLOSED_BAG_COVERAGE" == "insufficient" ]]; then
        record_error "validation-config.txt" "result cannot be pass when closedBagCoverage=insufficient"
    fi
    if [[ "$CONFIG_RESULT" == "pass" && "$CONFIG_CPU" != "Apple Silicon" ]]; then
        record_error "validation-config.txt" "result cannot be pass without Apple Silicon MacBook evidence"
    fi
    if [[ "$CONFIG_RESULT" == "pass" && "$CONFIG_HARDWARE_CLASS" != "MacBook" ]]; then
        record_error "validation-config.txt" "result cannot be pass without supported MacBook evidence"
    fi
    if [[ "$CONFIG_FAIL_CLOSED_CONTRACT" != "covered" ]]; then
        record_error "validation-config.txt" "failClosedContract must be covered"
    fi
    if ! is_choice_value "$CONFIG_RESULT" "pass" "fail" "inconclusive"; then
        record_error "validation-config.txt" "result must be pass, fail, or inconclusive"
    fi
}

verify_manual_result() {
    require_file "manual-result.md" "$MANUAL_FILE"
    [[ -f "$MANUAL_FILE" ]] || return

    for label in \
        "Case ID" \
        "Provider source" \
        "Helper-owned provider" \
        "Numeric cutoff source" \
        "No user-visible prompts" \
        "ProcessInfo role" \
        "Freshest reading age seconds" \
        "Active cadence seconds" \
        "Idle cadence seconds" \
        "Timeout seconds" \
        "Closed-bag coverage" \
        "Fail-closed cases recorded" \
        "Result"
    do
        check_required_field "$label"
    done

    check_choice_field "Provider source" "powermetrics" "ioreg-smc" "ioreg-pmu" "thermal-levels" "SMC" "IOReport" "other"
    check_choice_field "Helper-owned provider" "yes"
    check_choice_field "Numeric cutoff source" "yes"
    check_choice_field "No user-visible prompts" "yes"
    check_choice_field "ProcessInfo role" "supplemental-only"
    check_choice_field "Closed-bag coverage" "accepted" "requires-combined-signals" "insufficient"
    check_choice_field "Fail-closed cases recorded" "yes"
    check_choice_field "Result" "pass" "fail" "inconclusive"

    local provider_source freshest_age active_cadence idle_cadence timeout closed_bag result
    provider_source="$(field_value "Provider source" "$MANUAL_FILE" 2>/dev/null || true)"
    provider_source="$(trim_value "$provider_source")"
    if [[ -n "$CONFIG_PROVIDER_SOURCE" && "$provider_source" != "$CONFIG_PROVIDER_SOURCE" ]]; then
        record_error "manual-result.md" "Provider source must match validation-config providerSource"
    fi

    freshest_age="$(numeric_field_value "Freshest reading age seconds")"
    if ! is_nonnegative_number "$freshest_age"; then
        record_error "manual-result.md" "Freshest reading age seconds must be numeric"
    elif awk -v age="$freshest_age" -v max="$CONFIG_FRESHNESS_MAX_AGE_SECONDS" 'BEGIN { exit !(age > max) }'; then
        record_error "manual-result.md" "Freshest reading age seconds must be within freshnessMaxAgeSeconds"
    fi

    active_cadence="$(numeric_field_value "Active cadence seconds")"
    if [[ "$active_cadence" != "$CONFIG_ACTIVE_CADENCE_SECONDS" ]]; then
        record_error "manual-result.md" "Active cadence seconds must match validation-config activeCadenceSeconds"
    fi
    idle_cadence="$(numeric_field_value "Idle cadence seconds")"
    if [[ "$idle_cadence" != "$CONFIG_IDLE_CADENCE_SECONDS" ]]; then
        record_error "manual-result.md" "Idle cadence seconds must match validation-config idleCadenceSeconds"
    fi
    timeout="$(numeric_field_value "Timeout seconds")"
    if [[ "$timeout" != "$CONFIG_TIMEOUT_SECONDS" ]]; then
        record_error "manual-result.md" "Timeout seconds must match validation-config timeoutSeconds"
    fi

    closed_bag="$(field_value "Closed-bag coverage" "$MANUAL_FILE" 2>/dev/null || true)"
    closed_bag="$(trim_value "$closed_bag")"
    if [[ -n "$CONFIG_CLOSED_BAG_COVERAGE" && "$closed_bag" != "$CONFIG_CLOSED_BAG_COVERAGE" ]]; then
        record_error "manual-result.md" "Closed-bag coverage must match validation-config closedBagCoverage"
    fi

    result="$(field_value "Result" "$MANUAL_FILE" 2>/dev/null || true)"
    result="$(trim_value "$result")"
    if [[ -n "$CONFIG_RESULT" && "$result" != "$CONFIG_RESULT" ]]; then
        record_error "manual-result.md" "Result must match validation-config result"
    fi
}

verify_evidence_path() {
    local check_id="$1"
    local evidence_path="$2"

    if is_unfilled_value "$evidence_path"; then
        record_error "$check_id" "evidence row requires evidencePath"
        return
    fi
    if [[ "$evidence_path" == /* ]] || path_has_parent_segment "$evidence_path"; then
        record_error "$check_id" "evidencePath must be a relative path inside the evidence package"
        return
    fi
    if path_has_symlink_component "$evidence_path"; then
        record_error "$check_id" "evidencePath must not contain symlinks: $evidence_path"
        return
    fi

    local resolved_path="$MANIFEST_DIR/$evidence_path"
    if [[ -f "$resolved_path" ]]; then
        if [[ ! -s "$resolved_path" ]]; then
            record_error "$check_id" "evidence file is empty: $evidence_path"
        elif has_placeholder_content "$resolved_path"; then
            record_error "$check_id" "evidence file contains placeholder content: $evidence_path"
        fi
    elif [[ -d "$resolved_path" ]]; then
        if find "$resolved_path" -type l -print -quit | grep -q .; then
            record_error "$check_id" "evidence directory must not contain symlinks: $evidence_path"
        elif ! find "$resolved_path" -type f -size +0c -print -quit | grep -q .; then
            record_error "$check_id" "evidence directory has no non-empty files: $evidence_path"
        elif directory_has_placeholder_content "$resolved_path"; then
            record_error "$check_id" "evidence directory contains placeholder content: $evidence_path"
        fi
    else
        record_error "$check_id" "evidencePath does not exist: $evidence_path"
    fi
}

verify_manifest() {
    local header
    IFS= read -r header <"$MANIFEST_FILE" || true
    if [[ "$header" != $'checkId\tstatus\tevidencePath\tnote' ]]; then
        echo "Manifest header must be: checkId<TAB>status<TAB>evidencePath<TAB>note" >&2
        exit 2
    fi

    local row_count=0
    local line_number=1
    local line field_count check_id row_status evidence_path note
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        line_number=$((line_number + 1))
        [[ -z "${line:-}" ]] && continue
        row_count=$((row_count + 1))

        field_count="$(awk -F '\t' '{ print NF }' <<<"$line")"
        if [[ "$field_count" -ne 4 ]]; then
            record_error "manifest:$line_number" "row must have exactly 4 tab-separated columns"
            continue
        fi
        check_id="$(trim_value "$(awk -F '\t' '{ print $1 }' <<<"$line")")"
        row_status="$(trim_value "$(awk -F '\t' '{ print $2 }' <<<"$line")")"
        evidence_path="$(trim_value "$(awk -F '\t' '{ print $3 }' <<<"$line")")"
        note="$(trim_value "$(awk -F '\t' '{ print $4 }' <<<"$line")")"

        if is_unfilled_value "$check_id"; then
            record_error "manifest:$line_number" "checkId is missing or placeholder"
            continue
        fi
        if ! is_known_id "$check_id"; then
            record_error "$check_id" "unknown checkId"
            continue
        fi
        if has_seen_id "$check_id"; then
            record_error "$check_id" "duplicate manifest row"
            continue
        fi
        SEEN_CHECK_IDS+=("$check_id")
        if [[ "$check_id" == "combined-sensor-signal" ]]; then
            COMBINED_SENSOR_STATUS="$row_status"
        fi

        if is_required_id "$check_id"; then
            if [[ "$row_status" != "evidence" ]]; then
                record_error "$check_id" "required check must use status evidence"
                continue
            fi
            verify_evidence_path "$check_id" "$evidence_path"
        else
            case "$row_status" in
                evidence)
                    verify_evidence_path "$check_id" "$evidence_path"
                    ;;
                n/a)
                    if is_unfilled_value "$note"; then
                        record_error "$check_id" "n/a row requires an explicit note"
                    fi
                    ;;
                *)
                    record_error "$check_id" "optional check status must be evidence or n/a"
                    ;;
            esac
        fi
    done < <(tail -n +2 "$MANIFEST_FILE")

    if [[ "$row_count" -eq 0 ]]; then
        record_error "manifest" "manifest has no evidence rows"
    fi

    local required_id
    while IFS= read -r required_id; do
        if ! has_seen_id "$required_id"; then
            record_error "$required_id" "missing required manifest row"
        fi
    done < <(required_check_ids)

    if [[ "$CONFIG_CLOSED_BAG_COVERAGE" == "requires-combined-signals" ]]; then
        if [[ "$COMBINED_SENSOR_STATUS" != "evidence" ]]; then
            record_error "combined-sensor-signal" "closedBagCoverage=requires-combined-signals requires combined signal evidence"
        fi
    fi
}

verify_config
verify_manual_result
verify_manifest

if [[ "$case_errors" -ne 0 ]]; then
    echo "Temperature provider proof verification failed with $case_errors error(s)." >&2
    exit 1
fi

echo "Temperature provider proof verification passed."
