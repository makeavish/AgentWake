#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/bag-mode-primitive-matrix-review.sh ..." >&2
    exit 2
fi
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_ROOT=""
OUTPUT_FILE=""

usage() {
    cat <<'EOF'
Usage: scripts/bag-mode-primitive-matrix-review.sh --evidence-root DIR [--output PATH]

Reviews #29 Bag Mode primitive case artifacts and emits an advisory TSV report
for the known matrix rows. The script never edits matrix-manifest.tsv.

Report columns:

caseId	recommendation	evidenceDir	note
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
        --output)
            if [[ "$#" -lt 2 ]]; then
                echo "--output requires a value" >&2
                exit 2
            fi
            OUTPUT_FILE="$2"
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

if [[ -z "$EVIDENCE_ROOT" ]]; then
    echo "Provide --evidence-root." >&2
    usage >&2
    exit 2
fi

if [[ ! -d "$EVIDENCE_ROOT" ]]; then
    echo "Evidence root is not a directory: $EVIDENCE_ROOT" >&2
    exit 2
fi

EVIDENCE_ROOT="$(cd "$EVIDENCE_ROOT" && pwd)"

REPORT_TARGET="/dev/stdout"
if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    REPORT_TARGET="$OUTPUT_FILE"
fi

matrix_rows=(
    apple-silicon-ac-internal-open-normal
    apple-silicon-ac-internal-closed-normal
    apple-silicon-ac-internal-reopen-normal
    apple-silicon-battery-internal-open-normal
    apple-silicon-battery-internal-closed-normal
    apple-silicon-battery-internal-reopen-normal
    apple-silicon-ac-external-display-normal
    apple-silicon-battery-external-display-normal
    apple-silicon-ac-no-external-display-normal
    apple-silicon-battery-no-external-display-normal
    apple-silicon-ac-internal-app-quit
    apple-silicon-battery-internal-app-quit
    apple-silicon-ac-internal-crash
    apple-silicon-battery-internal-crash
    apple-silicon-ac-internal-reboot-held
    apple-silicon-battery-internal-reboot-held
    macos-13-host
    macos-14-host
    macos-15plus-host
    intel-host
    helper-restart-after-27
    helper-upgrade-after-27
)

row() {
    local case_id="$1"
    local recommendation="$2"
    local evidence_dir="$3"
    local note="$4"
    printf '%s\t%s\t%s\t%s\n' "$case_id" "$recommendation" "$evidence_dir" "$note"
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

trim_value() {
    printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

slug_value() {
    local value="$1"
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    value="${value// /-}"
    printf '%s\n' "$value"
}

row_for_case() {
    local manual="$1"
    local cpu power display lid lifecycle
    cpu="$(trim_value "$(field_value "CPU" "$manual")")"
    power="$(trim_value "$(field_value "Power" "$manual")")"
    display="$(trim_value "$(field_value "Display" "$manual")")"
    lid="$(trim_value "$(field_value "Lid path" "$manual")")"
    lifecycle="$(trim_value "$(field_value "Lifecycle path" "$manual")")"

    local cpu_slug power_slug display_slug lid_slug lifecycle_slug
    case "$cpu" in
        "Apple Silicon") cpu_slug="apple-silicon" ;;
        Intel) cpu_slug="intel" ;;
        *) return 1 ;;
    esac
    case "$power" in
        AC) power_slug="ac" ;;
        Battery) power_slug="battery" ;;
        *) return 1 ;;
    esac
    display_slug="$(slug_value "$display")"
    lifecycle_slug="$(slug_value "$lifecycle")"

    case "$lid" in
        open) lid_slug="open" ;;
        closed) lid_slug="closed" ;;
        "reopen recovery") lid_slug="reopen" ;;
        *) return 1 ;;
    esac

    if [[ "$cpu_slug" != "apple-silicon" ]]; then
        return 1
    fi

    case "$lifecycle_slug" in
        normal)
            case "$display_slug" in
                internal-only)
                    printf '%s-%s-internal-%s-normal\n' "$cpu_slug" "$power_slug" "$lid_slug"
                    ;;
                external-display|no-external-display)
                    printf '%s-%s-%s-normal\n' "$cpu_slug" "$power_slug" "$display_slug"
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        app-quit|crash)
            [[ "$display_slug" == "internal-only" ]] || return 1
            printf '%s-%s-internal-%s\n' "$cpu_slug" "$power_slug" "$lifecycle_slug"
            ;;
        reboot)
            [[ "$display_slug" == "internal-only" ]] || return 1
            printf '%s-%s-internal-reboot-held\n' "$cpu_slug" "$power_slug"
            ;;
        *)
            return 1
            ;;
    esac
}

case_dirs=()
if [[ -f "$EVIDENCE_ROOT/validation-config.txt" ]]; then
    case_dirs+=("$EVIDENCE_ROOT")
else
    shopt -s nullglob
    for candidate in "$EVIDENCE_ROOT"/*; do
        if [[ -d "$candidate" && -f "$candidate/validation-config.txt" ]]; then
            case_dirs+=("$candidate")
        fi
    done
    shopt -u nullglob
fi

review_rows="$(mktemp -t agentwake-bag-mode-matrix-review.XXXXXX)"
cleanup() {
    rm -f "$review_rows"
}
trap cleanup EXIT

for case_dir in "${case_dirs[@]}"; do
    if ! "$ROOT_DIR/scripts/bag-mode-primitive-matrix-verify.sh" --case-dir "$case_dir" >/dev/null 2>&1; then
        continue
    fi

    manual="$case_dir/manual-result.md"
    relative_dir="$case_dir"
    if [[ "$relative_dir" == "$EVIDENCE_ROOT/"* ]]; then
        relative_dir="${relative_dir#"$EVIDENCE_ROOT/"}"
    fi

    row_id="$(row_for_case "$manual" || true)"
    if [[ -n "${row_id:-}" ]]; then
        result="$(trim_value "$(field_value "Result" "$manual")")"
        sleep_blocked="$(trim_value "$(field_value "Lid-close sleep blocked" "$manual")")"
        recovered="$(trim_value "$(field_value "Reopen recovered cleanly" "$manual")")"

        printf '%s\t%s\t%s\t%s\n' \
            "$row_id" \
            "promote-candidate" \
            "$relative_dir" \
            "verified apply-mode evidence; result=$result; lidCloseSleepBlocked=$sleep_blocked; reopenRecovered=$recovered" >>"$review_rows"
    fi

    macos="$(trim_value "$(field_value "macOS" "$manual")")"
    if [[ "$macos" =~ ^(macOS[[:space:]]+)?([0-9]+)(\.[0-9]+)*\+?$ ]]; then
        macos_major="${BASH_REMATCH[2]}"
        case "$macos_major" in
            13) host_row="macos-13-host" ;;
            14) host_row="macos-14-host" ;;
            *) host_row="macos-15plus-host" ;;
        esac
        printf '%s\t%s\t%s\t%s\n' \
            "$host_row" \
            "promote-candidate" \
            "$relative_dir" \
            "verified evidence captured on macOS $macos" >>"$review_rows"
    fi

    cpu="$(trim_value "$(field_value "CPU" "$manual")")"
    if [[ "$cpu" == "Intel" ]]; then
        printf '%s\t%s\t%s\t%s\n' \
            "intel-host" \
            "promote-candidate" \
            "$relative_dir" \
            "verified evidence captured on Intel host" >>"$review_rows"
    fi
done

{
    printf 'caseId\trecommendation\tevidenceDir\tnote\n'
    for case_id in "${matrix_rows[@]}"; do
        if [[ "$case_id" == "helper-restart-after-27" ]]; then
            row "$case_id" "deferred" "" "blocked until #27 produces a validated no-membership helper prototype"
            continue
        fi
        if [[ "$case_id" == "helper-upgrade-after-27" ]]; then
            row "$case_id" "deferred" "" "blocked until #27 produces validated helper update evidence"
            continue
        fi

        matched_row="$(awk -F '\t' -v id="$case_id" '$1 == id { line = $0 } END { if (line != "") print line }' "$review_rows")"
        if [[ -n "$matched_row" ]]; then
            printf '%s\n' "$matched_row"
        else
            row "$case_id" "keep-todo" "" "no reviewed evidence directory matched this matrix row"
        fi
    done
} >"$REPORT_TARGET"
