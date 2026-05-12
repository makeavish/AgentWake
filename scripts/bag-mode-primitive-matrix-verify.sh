#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/bag-mode-primitive-matrix-verify.sh ..." >&2
    exit 2
fi
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_ROOT=""
MANIFEST_FILE=""
CASE_DIRS=()

usage() {
    cat <<'EOF'
Usage: scripts/bag-mode-primitive-matrix-verify.sh [options]

Checks Bag Mode primitive evidence directories for the required #29 files and
manual-result fields. This verifier does not prove the matrix passed; it only
fails incomplete or placeholder evidence before it is attached to #29.

Options:
  --evidence-root <dir>   Directory containing one or more case directories
  --manifest <path>       TSV manifest with caseId, status, evidenceDir, naReason
  --case-dir <dir>        Verify a specific case directory; repeatable
  -h, --help              Show this help

Examples:
  scripts/bag-mode-primitive-matrix-verify.sh \
    --evidence-root .build/power-validation/bag-mode-matrix

  scripts/bag-mode-primitive-matrix-verify.sh \
    --manifest .build/power-validation/bag-mode-matrix/matrix-manifest.tsv

  scripts/bag-mode-primitive-matrix-verify.sh \
    --case-dir .build/power-validation/bag-mode-matrix/apple-silicon-battery
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --evidence-root)
            if [[ "$#" -lt 2 ]]; then
                echo "--evidence-root requires a value" >&2
                exit 2
            fi
            EVIDENCE_ROOT="$2"
            shift 2
            ;;
        --manifest)
            if [[ "$#" -lt 2 ]]; then
                echo "--manifest requires a value" >&2
                exit 2
            fi
            MANIFEST_FILE="$2"
            shift 2
            ;;
        --case-dir)
            if [[ "$#" -lt 2 ]]; then
                echo "--case-dir requires a value" >&2
                exit 2
            fi
            CASE_DIRS+=("$2")
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

if [[ -z "$EVIDENCE_ROOT" && -z "$MANIFEST_FILE" && "${#CASE_DIRS[@]}" -eq 0 ]]; then
    echo "Provide --evidence-root, --manifest, or at least one --case-dir." >&2
    usage >&2
    exit 2
fi

if [[ -n "$EVIDENCE_ROOT" && -z "$MANIFEST_FILE" ]]; then
    if [[ ! -d "$EVIDENCE_ROOT" ]]; then
        echo "Evidence root is not a directory: $EVIDENCE_ROOT" >&2
        exit 2
    fi

    if [[ -f "$EVIDENCE_ROOT/validation-config.txt" ]]; then
        shopt -s nullglob
        child_cases=("$EVIDENCE_ROOT"/*/validation-config.txt)
        shopt -u nullglob
        if [[ "${#child_cases[@]}" -gt 0 ]]; then
            echo "Evidence root contains both a root case and child case directories; use --case-dir or --manifest explicitly." >&2
            exit 2
        fi
        CASE_DIRS+=("$EVIDENCE_ROOT")
    else
        shopt -s nullglob
        for candidate in "$EVIDENCE_ROOT"/*; do
            if [[ -d "$candidate" && -f "$candidate/validation-config.txt" ]]; then
                CASE_DIRS+=("$candidate")
            fi
        done
        shopt -u nullglob
    fi
fi

if [[ -z "$MANIFEST_FILE" && "${#CASE_DIRS[@]}" -eq 0 ]]; then
    echo "No evidence case directories found." >&2
    exit 1
fi

case_errors=0

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

is_unfilled_value() {
    local value
    value="$(printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

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

record_error() {
    local case_name="$1"
    local message="$2"
    printf 'ERROR [%s] %s\n' "$case_name" "$message" >&2
    case_errors=$((case_errors + 1))
}

require_file() {
    local case_name="$1"
    local file="$2"
    if [[ ! -f "$file" ]]; then
        record_error "$case_name" "missing file: ${file}"
    elif [[ ! -s "$file" ]]; then
        record_error "$case_name" "empty file: ${file}"
    fi
}

require_command_output_file() {
    local case_name="$1"
    local file="$2"
    require_file "$case_name" "$file"
    if [[ -s "$file" ]] && ! head -n 1 "$file" | grep -q '^\$ '; then
        record_error "$case_name" "snapshot command output is missing command header: ${file}"
    elif [[ -s "$file" && "$(wc -l <"$file" | tr -d '[:space:]')" -lt 2 ]]; then
        record_error "$case_name" "snapshot command output has no captured command body: ${file}"
    fi
}

require_snapshot() {
    local case_name="$1"
    local dir="$2"
    if [[ ! -d "$dir" ]]; then
        record_error "$case_name" "missing snapshot directory: ${dir}"
        return
    fi

    require_file "$case_name" "$dir/metadata.txt"
    for file in pmset-custom.txt pmset-assertions.txt ioreg-power.txt; do
        require_command_output_file "$case_name" "$dir/$file"
    done
}

check_required_field() {
    local case_name="$1"
    local label="$2"
    local file="$3"
    local value

    if ! value="$(field_value "$label" "$file")"; then
        record_error "$case_name" "manual-result.md missing field: $label"
        return
    fi

    if is_unfilled_value "$value"; then
        record_error "$case_name" "manual-result.md has placeholder value for: $label"
    fi
}

check_choice_field() {
    local case_name="$1"
    local label="$2"
    local file="$3"
    shift 3
    local value

    if ! value="$(field_value "$label" "$file")"; then
        record_error "$case_name" "manual-result.md missing field: $label"
        return
    fi

    value="$(printf '%s' "$value" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if ! is_choice_value "$value" "$@"; then
        record_error "$case_name" "manual-result.md field '$label' must be one of: $*"
    fi
}

trim_value() {
    printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

verify_case_dir() {
    local case_dir="$1"
    local expected_case_id="${2:-}"
    local case_name
    case_name="$(basename "$case_dir")"

    if [[ ! -d "$case_dir" ]]; then
        record_error "$case_name" "case path is not a directory: $case_dir"
        return
    fi

    local config="$case_dir/validation-config.txt"
    local manual="$case_dir/manual-result.md"
    require_file "$case_name" "$config"
    require_file "$case_name" "$manual"
    [[ -f "$config" && -f "$manual" ]] || return

    local case_id mode test_only reboot_held metadata_redacted candidate_command previous_disablesleep config_rollback_command
    case_id="$(value_for_key caseId "$config" 2>/dev/null || true)"
    mode="$(value_for_key mode "$config" 2>/dev/null || true)"
    test_only="$(value_for_key testOnly "$config" 2>/dev/null || true)"
    reboot_held="$(value_for_key rebootHeld "$config" 2>/dev/null || true)"
    metadata_redacted="$(value_for_key metadataRedacted "$config" 2>/dev/null || true)"
    candidate_command="$(value_for_key candidateCommand "$config" 2>/dev/null || true)"
    previous_disablesleep="$(value_for_key previousDisablesleep "$config" 2>/dev/null || true)"
    config_rollback_command="$(value_for_key rollbackCommand "$config" 2>/dev/null || true)"

    if is_unfilled_value "$case_id"; then
        record_error "$case_name" "validation-config.txt caseId is missing or placeholder"
    elif [[ -n "$expected_case_id" && "$case_id" != "$expected_case_id" ]]; then
        record_error "$case_name" "validation-config.txt caseId '$case_id' does not match manifest caseId '$expected_case_id'"
    fi
    if [[ "$mode" != "apply" ]]; then
        record_error "$case_name" "validation-config.txt mode must be apply for #29 evidence"
    fi
    if [[ "$test_only" != "false" ]]; then
        record_error "$case_name" "validation-config.txt testOnly must be false for #29 evidence"
    fi
    if [[ "$candidate_command" != "/usr/bin/pmset disablesleep 1" ]]; then
        record_error "$case_name" "validation-config.txt candidateCommand must be /usr/bin/pmset disablesleep 1"
    fi
    if [[ ! "$previous_disablesleep" =~ ^[0-9]+$ ]]; then
        record_error "$case_name" "validation-config.txt previousDisablesleep must be numeric"
    elif [[ "$config_rollback_command" != "/usr/bin/pmset disablesleep $previous_disablesleep" ]]; then
        record_error "$case_name" "validation-config.txt rollbackCommand must restore previousDisablesleep"
    fi
    if [[ "$metadata_redacted" != "true" ]]; then
        record_error "$case_name" "validation-config.txt metadataRedacted must be true"
    fi

    require_snapshot "$case_name" "$case_dir/before"
    require_snapshot "$case_name" "$case_dir/during-applied"
    require_snapshot "$case_name" "$case_dir/after-rollback"

    local lifecycle
    lifecycle="$(field_value "Lifecycle path" "$manual" 2>/dev/null || true)"
    if [[ "$reboot_held" == "1" || "$lifecycle" == "reboot" ]]; then
        require_snapshot "$case_name" "$case_dir/post-reboot"
    else
        require_snapshot "$case_name" "$case_dir/after-lid-window"
    fi

    for label in \
        "Case ID" \
        "macOS" \
        "CPU" \
        "Power" \
        "Display" \
        "Lid path" \
        "Lifecycle path" \
        "Applied command" \
        "Prior disablesleep value" \
        "Rollback command" \
        "Reboot state after held primitive"
    do
        check_required_field "$case_name" "$label" "$manual"
    done

    local manual_case_id prior_value applied_command rollback_command
    manual_case_id="$(field_value "Case ID" "$manual" 2>/dev/null || true)"
    manual_case_id="$(trim_value "$manual_case_id")"
    if [[ -n "$case_id" && -n "$manual_case_id" && "$case_id" != "$manual_case_id" ]]; then
        record_error "$case_name" "manual-result.md Case ID '$manual_case_id' does not match validation-config caseId '$case_id'"
    fi

    prior_value="$(field_value "Prior disablesleep value" "$manual" 2>/dev/null || true)"
    prior_value="$(trim_value "$prior_value")"
    if [[ ! "$prior_value" =~ ^[0-9]+$ ]]; then
        record_error "$case_name" "Prior disablesleep value must be numeric"
    elif [[ "$previous_disablesleep" =~ ^[0-9]+$ && "$prior_value" != "$previous_disablesleep" ]]; then
        record_error "$case_name" "Prior disablesleep value must match validation-config previousDisablesleep"
    fi

    local macos_value macos_major reboot_state
    macos_value="$(field_value "macOS" "$manual" 2>/dev/null || true)"
    macos_value="$(trim_value "$macos_value")"
    if [[ "$macos_value" =~ ^(macOS[[:space:]]+)?([0-9]+)(\.[0-9]+)*\+?$ ]]; then
        macos_major="${BASH_REMATCH[2]}"
        if [[ "$macos_major" -lt 13 ]]; then
            record_error "$case_name" "macOS value must be 13 or newer"
        fi
    else
        record_error "$case_name" "macOS value must look like a macOS version, for example 15.0"
    fi

    applied_command="$(field_value "Applied command" "$manual" 2>/dev/null || true)"
    if [[ ! "$applied_command" =~ (^|[^[:alnum:]_./-])/usr/bin/pmset[[:space:]]+disablesleep[[:space:]]+1([^0-9]|$) ]]; then
        record_error "$case_name" "Applied command must include /usr/bin/pmset disablesleep 1"
    fi

    rollback_command="$(field_value "Rollback command" "$manual" 2>/dev/null || true)"
    if [[ "$prior_value" =~ ^[0-9]+$ &&
          ! "$rollback_command" =~ (^|[^[:alnum:]_./-])/usr/bin/pmset[[:space:]]+disablesleep[[:space:]]+$prior_value([^0-9]|$) ]]; then
        record_error "$case_name" "Rollback command must restore the prior disablesleep value"
    fi

    reboot_state="$(field_value "Reboot state after held primitive" "$manual" 2>/dev/null || true)"
    reboot_state="$(trim_value "$reboot_state")"
    if [[ "$reboot_held" == "1" || "$lifecycle" == "reboot" ]]; then
        if [[ "$reboot_state" == N/A* || "$reboot_state" == n/a* ]]; then
            record_error "$case_name" "reboot-held cases must record actual reboot state, not N/A"
        fi
    fi

    check_choice_field "$case_name" "Power" "$manual" "AC" "Battery"
    check_choice_field "$case_name" "CPU" "$manual" "Apple Silicon" "Intel"
    check_choice_field "$case_name" "Display" "$manual" "internal-only" "external-display" "no-external-display"
    check_choice_field "$case_name" "Lid path" "$manual" "open" "closed" "reopen recovery"
    check_choice_field "$case_name" "Lifecycle path" "$manual" "normal" "app-quit" "crash" "reboot" "helper-restart" "helper-upgrade"
    check_choice_field "$case_name" "Lid-close sleep blocked" "$manual" "yes" "no" "inconclusive"
    check_choice_field "$case_name" "Reopen recovered cleanly" "$manual" "yes" "no" "inconclusive"
    check_choice_field "$case_name" "Result" "$manual" "pass" "fail" "inconclusive"
}

verify_manifest() {
    local manifest="$1"
    if [[ ! -f "$manifest" ]]; then
        echo "Manifest is not a file: $manifest" >&2
        exit 2
    fi

    local manifest_dir
    manifest_dir="$(cd "$(dirname "$manifest")" && pwd)"

    local header
    IFS= read -r header <"$manifest" || true
    if [[ "$header" != $'caseId\tstatus\tevidenceDir\tnaReason' ]]; then
        echo "Manifest header must be: caseId<TAB>status<TAB>evidenceDir<TAB>naReason" >&2
        exit 2
    fi

    local row_count=0
    local evidence_count=0
    local line_number=1
    local line field_count case_id row_status evidence_dir na_reason
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        line_number=$((line_number + 1))
        [[ -z "${line:-}" ]] && continue
        row_count=$((row_count + 1))

        field_count="$(awk -F '\t' '{ print NF }' <<<"$line")"
        if [[ "$field_count" -ne 4 ]]; then
            record_error "manifest:$line_number" "too many columns"
            continue
        fi
        case_id="$(awk -F '\t' '{ print $1 }' <<<"$line")"
        row_status="$(awk -F '\t' '{ print $2 }' <<<"$line")"
        evidence_dir="$(awk -F '\t' '{ print $3 }' <<<"$line")"
        na_reason="$(awk -F '\t' '{ print $4 }' <<<"$line")"

        if is_unfilled_value "${case_id:-}"; then
            record_error "manifest:$line_number" "caseId is missing or placeholder"
            continue
        fi

        case "$row_status" in
            evidence)
                evidence_count=$((evidence_count + 1))
                if is_unfilled_value "${evidence_dir:-}"; then
                    record_error "$case_id" "evidence row requires evidenceDir"
                    continue
                fi
                local resolved_evidence_dir="$evidence_dir"
                if [[ "$resolved_evidence_dir" != /* ]]; then
                    resolved_evidence_dir="$manifest_dir/$resolved_evidence_dir"
                fi
                verify_case_dir "$resolved_evidence_dir" "$case_id"
                ;;
            n/a|deferred)
                if is_unfilled_value "${na_reason:-}"; then
                    record_error "$case_id" "$row_status row requires an explicit naReason"
                fi
                ;;
            *)
                record_error "$case_id" "status must be evidence, n/a, or deferred"
                ;;
        esac
    done < <(tail -n +2 "$manifest")

    if [[ "$row_count" -eq 0 ]]; then
        record_error "manifest" "manifest has no matrix rows"
    fi
    if [[ "$evidence_count" -eq 0 ]]; then
        record_error "manifest" "manifest must include at least one evidence row"
    fi
}

if [[ -n "$MANIFEST_FILE" ]]; then
    verify_manifest "$MANIFEST_FILE"
else
    for case_dir in "${CASE_DIRS[@]}"; do
        verify_case_dir "$case_dir"
    done
fi

if [[ "$case_errors" -ne 0 ]]; then
    echo "Bag Mode primitive matrix verification failed with $case_errors error(s)." >&2
    exit 1
fi

if [[ -n "$MANIFEST_FILE" ]]; then
    echo "Bag Mode primitive matrix manifest verification passed."
else
    echo "Bag Mode primitive matrix verification passed for ${#CASE_DIRS[@]} case(s)."
fi
