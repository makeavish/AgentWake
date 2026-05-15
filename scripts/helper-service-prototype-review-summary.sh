#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/helper-service-prototype-review-summary.sh ..." >&2
    exit 2
fi
set -euo pipefail

CAPTURE_REPORTS=()
FIXED_COMMAND_REPORTS=()
UPDATE_REPORTS=()
CLI_PROOF_DIRS=()
OUTPUT_FILE=""

usage() {
    cat <<'EOF'
Usage: scripts/helper-service-prototype-review-summary.sh [options]

Options:
  --capture-review PATH        TSV from helper-service-prototype-review-captures.sh
  --fixed-command-review PATH  TSV from helper-service-prototype-review-fixed-commands.sh
  --update-review PATH         TSV from helper-service-prototype-review-update.sh
  --cli-proof DIR              Artifact from helper-service-cli-outcome-proof.sh
  --output PATH                Write the summary TSV to PATH instead of stdout

Combines reviewed #27 advisory reports into one non-mutating gap summary. It
never edits prototype-manifest.tsv or manual-result.md.

Summary columns:

checkId	status	source	evidencePath	note
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --capture-review)
            if [[ "$#" -lt 2 ]]; then
                echo "--capture-review requires a value" >&2
                exit 2
            fi
            CAPTURE_REPORTS+=("$2")
            shift 2
            ;;
        --fixed-command-review)
            if [[ "$#" -lt 2 ]]; then
                echo "--fixed-command-review requires a value" >&2
                exit 2
            fi
            FIXED_COMMAND_REPORTS+=("$2")
            shift 2
            ;;
        --update-review)
            if [[ "$#" -lt 2 ]]; then
                echo "--update-review requires a value" >&2
                exit 2
            fi
            UPDATE_REPORTS+=("$2")
            shift 2
            ;;
        --cli-proof)
            if [[ "$#" -lt 2 ]]; then
                echo "--cli-proof requires a value" >&2
                exit 2
            fi
            CLI_PROOF_DIRS+=("$2")
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

if [[ "${#CAPTURE_REPORTS[@]}" -eq 0 &&
      "${#FIXED_COMMAND_REPORTS[@]}" -eq 0 &&
      "${#UPDATE_REPORTS[@]}" -eq 0 &&
      "${#CLI_PROOF_DIRS[@]}" -eq 0 ]]; then
    echo "Provide at least one review report or CLI proof artifact." >&2
    usage >&2
    exit 2
fi

REPORT_TARGET="/dev/stdout"
if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    REPORT_TARGET="$OUTPUT_FILE"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentwake-helper-review-summary.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
ORDER_FILE="$WORK_DIR/order.tsv"
CANDIDATES_FILE="$WORK_DIR/candidates.tsv"

cat >"$ORDER_FILE" <<'EOF'
app-bundle-or-install-layout	required
launchdaemon-plist	required
app-signing-or-auth-model	required
helper-signing-or-auth-model	required
caller-auth-model	required
fixed-command-api	required
spctl-or-gatekeeper-assessment	required
helper-install-or-register	required
helper-status-after-approval	required
admin-approval-or-password-flow	required
helper-bootstrap-after-approval	required
post-reboot-helper-bootstrap	required
root-ledger-schema-and-permissions	required
root-ledger-ownership-sample	required
helper-update-old-inactive	required
helper-update-ledger-compatibility	required
helper-repair-conflict	required
helper-uninstall	required
helper-uninstall-state-cleanup	required
cli-helper-status-repair-uninstall	required
failure-unpaired-caller	required
failure-wrong-bundle-id-or-label	required
failure-wrong-user	required
failure-stale-app-version	required
failure-denied-or-revoked-approval	required
launchctl-status	required
log-evidence	required
smappservice-rejection	optional
package-installer-signing	optional
homebrew-cask-semantics	optional
EOF

: >"$CANDIDATES_FILE"

require_file() {
    local path="$1"
    local label="$2"
    if [[ ! -f "$path" ]]; then
        echo "$label is not a file: $path" >&2
        exit 2
    fi
}

require_dir() {
    local path="$1"
    local label="$2"
    if [[ ! -d "$path" ]]; then
        echo "$label is not a directory: $path" >&2
        exit 2
    fi
}

value_for_key() {
    local key="$1"
    local file="$2"
    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); found = 1 } END { if (!found) exit 1 }' "$file"
}

status_for_recommendation() {
    case "$1" in
        promote-candidate) echo "ready" ;;
        review-needed) echo "needs-review" ;;
        keep-todo) echo "missing" ;;
        not-applicable) echo "not-applicable" ;;
        *) echo "missing" ;;
    esac
}

append_candidate() {
    local check_id="$1"
    local status="$2"
    local source="$3"
    local evidence_path="$4"
    local note="$5"
    printf '%s\t%s\t%s\t%s\t%s\n' "$check_id" "$status" "$source" "$evidence_path" "$note" >>"$CANDIDATES_FILE"
}

append_capture_report() {
    local report="$1"
    require_file "$report" "Capture review report"
    local header
    IFS= read -r header <"$report" || true
    if [[ "$header" != $'checkId\trecommendation\tevidencePath\tnote' ]]; then
        echo "Capture/update review report header must be: checkId<TAB>recommendation<TAB>evidencePath<TAB>note" >&2
        echo "File: $report" >&2
        exit 2
    fi

    if awk -F '\t' 'NR > 1 && NF != 4 { exit 1 }' "$report"; then
        :
    else
        echo "Capture/update review report rows must have exactly four tab-separated columns: $report" >&2
        exit 2
    fi

    awk -F '\t' -v source="$report" '
        BEGIN { OFS = "\t" }
        NR == 1 { next }
        $1 == "" { next }
        {
            if ($2 == "promote-candidate") {
                status = "ready"
            } else if ($2 == "review-needed") {
                status = "needs-review"
            } else if ($2 == "not-applicable") {
                status = "not-applicable"
            } else {
                status = "missing"
            }
            print $1, status, source, $3, $4
        }
    ' "$report" >>"$CANDIDATES_FILE"
}

append_fixed_command_report() {
    local report="$1"
    require_file "$report" "Fixed-command review report"
    local header
    IFS= read -r header <"$report" || true
    if [[ "$header" != $'command\trecommendation\tartifactDir\tevidencePath\tnote' ]]; then
        echo "Fixed-command review report header must be: command<TAB>recommendation<TAB>artifactDir<TAB>evidencePath<TAB>note" >&2
        echo "File: $report" >&2
        exit 2
    fi

    if awk -F '\t' 'NR > 1 && NF != 5 { exit 1 }' "$report"; then
        :
    else
        echo "Fixed-command review report rows must have exactly five tab-separated columns: $report" >&2
        exit 2
    fi

    awk -F '\t' -v source="$report" '
        BEGIN { OFS = "\t" }
        NR == 1 { next }
        $1 != "fixed-command-api" { next }
        {
            if ($2 == "promote-candidate") {
                status = "ready"
            } else if ($2 == "review-needed") {
                status = "needs-review"
            } else if ($2 == "not-applicable") {
                status = "not-applicable"
            } else {
                status = "missing"
            }
            print "fixed-command-api", status, source, $4, $5
        }
    ' "$report" >>"$CANDIDATES_FILE"
}

append_cli_proof() {
    local artifact_dir="$1"
    require_dir "$artifact_dir" "CLI proof artifact"
    local config="$artifact_dir/validation-config.txt"
    local evidence="$artifact_dir/evidence/cli-helper-status-repair-uninstall.txt"
    local status_file="$artifact_dir/evidence/cli-helper-status-repair-uninstall.status"
    require_file "$config" "CLI proof validation-config.txt"

    local ready
    local expanded_coverage
    ready="$(value_for_key helperCliOutcomeProofReady "$config" 2>/dev/null || true)"
    expanded_coverage="$(value_for_key cliHelperStatusEnableDisableRepairUninstallCovered "$config" 2>/dev/null || true)"
    if [[ "$ready" == "true" &&
          "$expanded_coverage" == "true" &&
          -s "$evidence" &&
          -s "$status_file" &&
          "$(value_for_key exitCode "$status_file" 2>/dev/null || true)" == "0" ]]; then
        append_candidate cli-helper-status-repair-uninstall ready "$artifact_dir" evidence/cli-helper-status-repair-uninstall.txt "focused CLI helper status/enable/disable/repair/uninstall routing proof is ready"
    else
        append_candidate cli-helper-status-repair-uninstall missing "$artifact_dir" "" "CLI helper outcome proof is missing or not ready"
    fi
}

if [[ "${#CAPTURE_REPORTS[@]}" -gt 0 ]]; then
    for report in "${CAPTURE_REPORTS[@]}"; do
        append_capture_report "$report"
    done
fi
if [[ "${#FIXED_COMMAND_REPORTS[@]}" -gt 0 ]]; then
    for report in "${FIXED_COMMAND_REPORTS[@]}"; do
        append_fixed_command_report "$report"
    done
fi
if [[ "${#UPDATE_REPORTS[@]}" -gt 0 ]]; then
    for report in "${UPDATE_REPORTS[@]}"; do
        append_capture_report "$report"
    done
fi
if [[ "${#CLI_PROOF_DIRS[@]}" -gt 0 ]]; then
    for artifact_dir in "${CLI_PROOF_DIRS[@]}"; do
        append_cli_proof "$artifact_dir"
    done
fi

awk -F '\t' '
    BEGIN {
        OFS = "\t"
        rank["not-applicable"] = 1
        rank["missing"] = 2
        rank["needs-review"] = 3
        rank["ready"] = 4
    }
    NR == FNR {
        order[++order_count] = $1
        kind[$1] = $2
        next
    }
    {
        id = $1
        status = $2
        source = $3
        evidence = $4
        note = $5
        if (!(status in rank)) {
            status = "missing"
        }
        if (!(id in best_rank) || rank[status] > best_rank[id]) {
            best_rank[id] = rank[status]
            best_status[id] = status
            best_source[id] = source
            best_evidence[id] = evidence
            best_note[id] = note
        }
    }
    END {
        print "checkId", "status", "source", "evidencePath", "note"
        for (row_index = 1; row_index <= order_count; row_index++) {
            id = order[row_index]
            if (id in best_status) {
                print id, best_status[id], best_source[id], best_evidence[id], best_note[id]
            } else if (kind[id] == "optional") {
                print id, "not-applicable", "", "", "optional row was not exercised by the supplied reports"
            } else {
                print id, "missing", "", "", "no supplied report promoted this required row"
            }
        }
    }
' "$ORDER_FILE" "$CANDIDATES_FILE" >"$REPORT_TARGET"
