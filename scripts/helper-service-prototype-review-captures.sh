#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/helper-service-prototype-review-captures.sh ..." >&2
    exit 2
fi
set -euo pipefail

ARTIFACT_DIR=""
OUTPUT_FILE=""
APPROVAL_FLOW_REVIEWED=false
ROOT_LEDGER_REVIEWED=false

usage() {
    cat <<'EOF'
Usage: scripts/helper-service-prototype-review-captures.sh --artifact-dir DIR [--output PATH]
       [--i-reviewed-operator-approval-flow]
       [--i-reviewed-root-ledger-evidence]

Reviews captured SMAppService helper prototype evidence for #27 and writes a
TSV report of manifest rows that look ready for manual promotion, rows that
still need human review, and rows that must remain TODO. The script never edits
manual-result.md or prototype-manifest.tsv.

The two --i-reviewed-* flags are intentionally explicit. They allow a reviewer
to promote rows whose mechanical evidence is present but whose meaning depends
on human review of operator approval/password flow or root-owned ledger evidence
that may be unreadable to the normal user by design.

Report columns:

checkId	recommendation	evidencePath	note
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --artifact-dir)
            if [[ "$#" -lt 2 ]]; then
                echo "--artifact-dir requires a value" >&2
                exit 2
            fi
            ARTIFACT_DIR="$2"
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
        --i-reviewed-operator-approval-flow)
            APPROVAL_FLOW_REVIEWED=true
            shift
            ;;
        --i-reviewed-root-ledger-evidence)
            ROOT_LEDGER_REVIEWED=true
            shift
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

if [[ -z "$ARTIFACT_DIR" ]]; then
    echo "Provide --artifact-dir." >&2
    usage >&2
    exit 2
fi

if [[ ! -d "$ARTIFACT_DIR" ]]; then
    echo "Artifact directory is not a directory: $ARTIFACT_DIR" >&2
    exit 2
fi

ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"
EVIDENCE_DIR="$ARTIFACT_DIR/evidence"
if [[ ! -d "$EVIDENCE_DIR" ]]; then
    echo "Artifact is missing evidence directory: $EVIDENCE_DIR" >&2
    exit 2
fi

REPORT_TARGET="/dev/stdout"
if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    REPORT_TARGET="$OUTPUT_FILE"
fi

evidence_file() {
    printf '%s/evidence/%s.txt' "$ARTIFACT_DIR" "$1"
}

status_file() {
    printf '%s/evidence/%s.status' "$ARTIFACT_DIR" "$1"
}

has_exit_zero() {
    local check_id="$1"
    grep -q '^exitCode=0$' "$(status_file "$check_id")" 2>/dev/null
}

has_file() {
    local check_id="$1"
    [[ -s "$(evidence_file "$check_id")" ]]
}

has_all() {
    local check_id="$1"
    shift
    local file
    file="$(evidence_file "$check_id")"
    [[ -s "$file" ]] || return 1

    local pattern
    for pattern in "$@"; do
        if ! grep -Fq "$pattern" "$file"; then
            return 1
        fi
    done
}

has_any() {
    local check_id="$1"
    shift
    local file
    file="$(evidence_file "$check_id")"
    [[ -s "$file" ]] || return 1

    local pattern
    for pattern in "$@"; do
        if grep -Fq "$pattern" "$file"; then
            return 0
        fi
    done
    return 1
}

has_auth_failure() {
    local check_id="$1"
    local expected="$2"
    local file
    file="$(evidence_file "$check_id")"
    [[ -s "$file" ]] || return 1
    grep -F 'authFailuresJson=' "$file" | grep -Fq "\"$expected\""
}

row() {
    local check_id="$1"
    local recommendation="$2"
    local path="$3"
    local note="$4"
    printf '%s\t%s\t%s\t%s\n' "$check_id" "$recommendation" "$path" "$note"
}

review_helper_status_after_approval() {
    if has_exit_zero helper-status-after-approval &&
       has_all helper-status-after-approval 'statusBeforeRaw=1' 'statusAfterRaw=1'; then
        row helper-status-after-approval promote-candidate evidence/helper-status-after-approval.txt "enabled status captured after approval"
    else
        row helper-status-after-approval keep-todo "" "missing enabled post-approval status capture"
    fi
}

review_admin_approval_flow() {
    if has_exit_zero helper-status-after-approval &&
       has_all helper-install-or-register 'statusAfterRaw=2' &&
       has_all helper-status-after-approval 'statusBeforeRaw=1' 'statusAfterRaw=1'; then
        if [[ "$APPROVAL_FLOW_REVIEWED" == true ]]; then
            row admin-approval-or-password-flow promote-candidate evidence/helper-install-or-register.txt "reviewed requiresApproval to enabled transition and operator approval/password flow"
        else
            row admin-approval-or-password-flow review-needed evidence/helper-install-or-register.txt "requiresApproval to enabled transition is present; confirm operator approval/password flow before promotion"
        fi
    else
        row admin-approval-or-password-flow keep-todo "" "requiresApproval to enabled transition not fully captured"
    fi
}

review_helper_bootstrap_after_approval() {
    if has_exit_zero helper-stdout-after-approval &&
       has_all helper-stdout-after-approval 'uid=0' 'euid=0' 'allowed=true' 'approvalState="approved"'; then
        row helper-bootstrap-after-approval promote-candidate evidence/helper-stdout-after-approval.txt "root helper stdout captured after approval"
    else
        row helper-bootstrap-after-approval keep-todo "" "missing root helper stdout after approval"
    fi
}

review_post_reboot_bootstrap() {
    if has_exit_zero helper-status-post-reboot &&
       has_all helper-status-post-reboot 'statusBeforeRaw=1' 'statusAfterRaw=1' &&
       has_all post-reboot-helper-bootstrap 'managed_by = com.apple.xpc.ServiceManagement' 'runs = 1' 'last exit code = 0' &&
       has_exit_zero helper-stdout-post-reboot &&
       has_all helper-stdout-post-reboot 'uid=0' 'euid=0' 'allowed=true' 'approvalState="approved"' '"event":"bagModeHelperLedgerSample"'; then
        row post-reboot-helper-bootstrap promote-candidate evidence/post-reboot-helper-bootstrap.txt "enabled status and launchctl bootstrap captured after reboot"
    else
        row post-reboot-helper-bootstrap keep-todo "" "missing enabled post-reboot status, launchctl bootstrap, or root helper stdout evidence"
    fi
}

review_root_ledger() {
    if has_all root-ledger-schema-and-permissions 'mode=-rw------- owner=root' &&
       has_exit_zero helper-stdout-after-approval &&
       has_all helper-stdout-after-approval '"schemaVersion":1' '"event":"bagModeHelperLedgerSample"'; then
        if [[ "$ROOT_LEDGER_REVIEWED" == true ]]; then
            row root-ledger-schema-and-permissions promote-candidate evidence/root-ledger-schema-and-permissions.txt "reviewed root 0600 ledger permissions and mirrored schema sample"
        else
            row root-ledger-schema-and-permissions review-needed evidence/root-ledger-schema-and-permissions.txt "root 0600 ledger permissions plus mirrored schema sample captured; content read may be permission denied by design"
        fi
    else
        row root-ledger-schema-and-permissions keep-todo "" "missing root ledger permissions or mirrored ledger schema sample"
    fi

    if has_all root-ledger-ownership-sample 'mode=-rw------- owner=root' &&
       has_exit_zero helper-stdout-after-approval &&
       has_all helper-stdout-after-approval '"ownerTokenHash"' '"helperGeneration"'; then
        if [[ "$ROOT_LEDGER_REVIEWED" == true ]]; then
            row root-ledger-ownership-sample promote-candidate evidence/root-ledger-ownership-sample.txt "reviewed root-owned ledger path and mirrored ownership fields"
        else
            row root-ledger-ownership-sample review-needed evidence/root-ledger-ownership-sample.txt "root-owned ledger path and mirrored ownership fields captured; content read may be permission denied by design"
        fi
    else
        row root-ledger-ownership-sample keep-todo "" "missing root ledger ownership mode or mirrored ownership fields"
    fi
}

review_launchctl_and_logs() {
    if has_exit_zero launchctl-status &&
       has_all launchctl-status 'managed_by = com.apple.xpc.ServiceManagement' 'runs = 1'; then
        row launchctl-status promote-candidate evidence/launchctl-status.txt "ServiceManagement launchctl state captured after approval"
    else
        row launchctl-status keep-todo "" "missing ServiceManagement launchctl state after approval"
    fi

    if has_exit_zero log-evidence && has_file log-evidence; then
        row log-evidence promote-candidate evidence/log-evidence.txt "unified log capture exists"
    else
        row log-evidence keep-todo "" "missing successful unified log capture"
    fi
}

review_uninstall() {
    if has_exit_zero helper-uninstall &&
       has_all helper-uninstall 'unregisterResult=success' 'statusBeforeRaw=1' 'statusAfterRaw=0' &&
       has_any launchctl-status-after-unregister 'Could not find service' 'service not found' 'Could not find specified service'; then
        row helper-uninstall promote-candidate evidence/helper-uninstall.txt "SMAppService unregister succeeded and launchctl no longer finds the daemon"
    else
        row helper-uninstall keep-todo "" "missing successful unregister and service-not-found cleanup evidence"
    fi

    row helper-uninstall-state-cleanup keep-todo "" "unregister cleanup is not helper-owned Bag Mode state cleanup proof"
}

review_remaining_rows() {
    review_static_evidence app-bundle-or-install-layout "prototype app bundle layout evidence exists"
    review_static_evidence launchdaemon-plist "LaunchDaemon plist evidence exists"
    review_static_evidence app-signing-or-auth-model "app signing/auth-model evidence exists"
    review_static_evidence helper-signing-or-auth-model "helper signing/auth-model evidence exists"
    review_static_evidence caller-auth-model "caller auth-model evidence exists"
    row fixed-command-api keep-todo "" "requires approved-helper evidence for status, enableBagMode, disableBagMode, repair, and uninstall in one reviewed package"
    review_static_evidence spctl-or-gatekeeper-assessment "Gatekeeper assessment evidence exists"
    review_static_evidence helper-install-or-register "helper install/register evidence exists"
    row helper-update-old-inactive keep-todo "" "requires real generation N to N+1 installed-helper update evidence"
    row helper-update-ledger-compatibility keep-todo "" "requires real update ledger compatibility or repair evidence"
    row helper-repair-conflict keep-todo "" "requires production restore conflict and repair behavior evidence"
    row cli-helper-status-repair-uninstall keep-todo "" "requires attached CLI helper status/repair/uninstall outcome evidence"
    review_failure_case failure-unpaired-caller "unpaired-caller"
    review_failure_case failure-wrong-bundle-id-or-label "wrong-bundle-id" "wrong-helper-label"
    review_failure_case failure-wrong-user "wrong-user"
    review_failure_case failure-stale-app-version "stale-app-version"
    review_failure_case failure-denied-or-revoked-approval "approval-denied" "approval-revoked"
    review_optional smappservice-rejection "SMAppService fallback rejection evidence exists" "SMAppService fallback not selected by this artifact"
    review_optional package-installer-signing "package installer signing evidence exists" "no package installer evidence in this artifact"
    review_optional homebrew-cask-semantics "Homebrew cask semantics evidence exists" "no Homebrew cask evidence in this artifact"
}

review_static_evidence() {
    local check_id="$1"
    local note="$2"
    if has_file "$check_id"; then
        row "$check_id" promote-candidate "evidence/$check_id.txt" "$note"
    else
        row "$check_id" keep-todo "" "missing $check_id evidence"
    fi
}

review_failure_case() {
    local check_id="$1"
    shift
    local patterns=(allowed=false commandAllowed=true)
    local expected

    if [[ "$check_id" == "failure-denied-or-revoked-approval" ]]; then
        patterns+=("observedExitCode[denied]=77" "observedExitCode[revoked]=77")
    else
        patterns+=("observedExitCode=77")
    fi

    if ! has_exit_zero "$check_id" || ! has_all "$check_id" "${patterns[@]}"; then
        row "$check_id" keep-todo "" "missing successful helper-auth failure capture for $check_id"
        return
    fi

    for expected in "$@"; do
        if ! has_auth_failure "$check_id" "$expected"; then
            row "$check_id" keep-todo "" "missing authFailuresJson marker for $expected"
            return
        fi
    done

    row "$check_id" promote-candidate "evidence/$check_id.txt" "helper-auth failure probe rejected the expected condition"
}

review_optional() {
    local check_id="$1"
    local evidence_note="$2"
    local missing_note="$3"
    if has_file "$check_id"; then
        row "$check_id" review-needed "evidence/$check_id.txt" "$evidence_note"
    else
        row "$check_id" not-applicable "" "$missing_note"
    fi
}

{
    printf 'checkId\trecommendation\tevidencePath\tnote\n'
    review_helper_status_after_approval
    review_admin_approval_flow
    review_helper_bootstrap_after_approval
    review_post_reboot_bootstrap
    review_root_ledger
    review_launchctl_and_logs
    review_uninstall
    review_remaining_rows
} >"$REPORT_TARGET"
