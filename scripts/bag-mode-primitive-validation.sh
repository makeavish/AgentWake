#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/power-validation/bag-mode-primitive-$(date -u +%Y%m%dT%H%M%SZ)"
CASE_ID=""
APPLY=0
HOLD_SECONDS="${AGENTWAKE_BAG_MODE_HOLD_SECONDS:-300}"
ACKNOWLEDGED=0
CONTINUE_OUTPUT=0
REBOOT_HELD=0
ROLLBACK_NEEDED=0
PREVIOUS_DISABLESLEEP=""
PMSET_BIN="/usr/bin/pmset"
TEST_PMSET=0

if [[ -n "${AGENTWAKE_PMSET_BIN:-}" ]]; then
    if [[ "${AGENTWAKE_BAG_MODE_PRIMITIVE_TEST_PMSET:-0}" != "1" ]]; then
        echo "AGENTWAKE_PMSET_BIN is for internal validation only; unset it for real #29 evidence." >&2
        exit 2
    fi
    PMSET_BIN="$AGENTWAKE_PMSET_BIN"
    TEST_PMSET=1
fi

usage() {
    cat <<'EOF'
Usage: scripts/closed-lid-primitive-validation.sh [options]

Captures Closed-Lid Mode primitive evidence for the candidate `pmset disablesleep`
path. By default this script is non-mutating and only writes a readiness
template plus baseline power snapshots.

Options:
  --output-dir <path>      Evidence directory to write
  --case-id <id>           Human-readable matrix case id
  --hold-seconds <n>       Seconds to leave disablesleep applied during manual lid test
  --apply                  Actually run pmset disablesleep 1, wait, then roll back
  --i-understand-this-changes-power-settings
                           Required with --apply
  --continue               Allow writing into an existing evidence directory
  --reboot-held            Mutating mode for reboot-while-held evidence; no trap rollback
  -h, --help               Show this help

Environment:
  AGENTWAKE_BAG_MODE_HOLD_SECONDS=<seconds>

Internal validation only:
  AGENTWAKE_BAG_MODE_PRIMITIVE_TEST_PMSET=1 AGENTWAKE_PMSET_BIN=<path>
      Runs against a fake pmset command. The matrix verifier rejects this
      output as test-only evidence.
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --output-dir)
            if [[ "$#" -lt 2 ]]; then
                echo "--output-dir requires a value" >&2
                exit 2
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --case-id)
            if [[ "$#" -lt 2 ]]; then
                echo "--case-id requires a value" >&2
                exit 2
            fi
            CASE_ID="$2"
            shift 2
            ;;
        --hold-seconds)
            if [[ "$#" -lt 2 ]]; then
                echo "--hold-seconds requires a value" >&2
                exit 2
            fi
            HOLD_SECONDS="$2"
            shift 2
            ;;
        --apply)
            APPLY=1
            shift
            ;;
        --i-understand-this-changes-power-settings)
            ACKNOWLEDGED=1
            shift
            ;;
        --continue)
            CONTINUE_OUTPUT=1
            shift
            ;;
        --reboot-held)
            REBOOT_HELD=1
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

if [[ "$APPLY" == "1" && "$ACKNOWLEDGED" != "1" ]]; then
    echo "--apply requires --i-understand-this-changes-power-settings" >&2
    exit 2
fi

if [[ "$REBOOT_HELD" == "1" && "$APPLY" != "1" ]]; then
    echo "--reboot-held requires --apply" >&2
    exit 2
fi

if [[ "$APPLY" == "1" && "$(id -u)" -ne 0 ]]; then
    echo "--apply must be run as root to guarantee non-interactive rollback" >&2
    echo "Re-run with: sudo scripts/closed-lid-primitive-validation.sh --apply --i-understand-this-changes-power-settings ..." >&2
    exit 2
fi

if ! [[ "$HOLD_SECONDS" =~ ^[0-9]+$ ]] || [[ "$HOLD_SECONDS" -le 0 ]]; then
    echo "--hold-seconds must be a positive integer" >&2
    exit 2
fi

if [[ -e "$OUTPUT_DIR" && "$CONTINUE_OUTPUT" != "1" ]]; then
    shopt -s nullglob dotglob
    existing=("$OUTPUT_DIR"/*)
    shopt -u nullglob dotglob
    if [[ "${#existing[@]}" -gt 0 ]]; then
        echo "Output directory is not empty: $OUTPUT_DIR" >&2
        echo "Use --continue to add to an existing evidence directory." >&2
        exit 2
    fi
fi

mkdir -p "$OUTPUT_DIR"

snapshot() {
    AGENTWAKE_PMSET_REDACT_METADATA=1 "$ROOT_DIR/scripts/pmset-snapshot.sh" "$1"
}

current_disablesleep() {
    "$PMSET_BIN" -g custom | awk '
        BEGIN {
            found = ""
            seen = 0
        }
        $1 == "disablesleep" {
            seen = 1
            found = $2
        }
        END {
            if (seen == 0) {
                print "0"
                exit 0
            }
            if (found !~ /^[0-9]+$/) {
                exit 1
            }
            print found
        }
    '
}

rollback() {
    local mode="${1:-strict}"
    local status=0

    if [[ "$ROLLBACK_NEEDED" != "1" ]]; then
        return 0
    fi

    {
        echo "$ ${PMSET_BIN} disablesleep ${PREVIOUS_DISABLESLEEP}"
        "$PMSET_BIN" disablesleep "$PREVIOUS_DISABLESLEEP"
    } >"$OUTPUT_DIR/rollback-command.txt" 2>&1 || status=$?

    if [[ "$status" -ne 0 ]]; then
        if [[ "$mode" == "strict" ]]; then
            echo "Rollback command failed; see $OUTPUT_DIR/rollback-command.txt" >&2
            return "$status"
        fi
        return 0
    fi

    local restored
    if ! restored="$(current_disablesleep)"; then
        if [[ "$mode" == "strict" ]]; then
            echo "Rollback verification failed: could not read disablesleep value" >&2
            return 1
        fi
        return 0
    fi

    if [[ "$restored" != "$PREVIOUS_DISABLESLEEP" ]]; then
        if [[ "$mode" == "strict" ]]; then
            echo "Rollback verification failed: expected disablesleep=$PREVIOUS_DISABLESLEEP, got $restored" >&2
            return 1
        fi
        return 0
    fi

    snapshot "$OUTPUT_DIR/after-rollback" >/dev/null || {
        if [[ "$mode" == "strict" ]]; then
            echo "Rollback snapshot failed" >&2
            return 1
        fi
    }
}

if [[ "$APPLY" == "1" ]]; then
    if ! PREVIOUS_DISABLESLEEP="$(current_disablesleep)"; then
        echo "Could not determine current pmset disablesleep value; refusing to mutate power settings." >&2
        exit 2
    fi
    if ! [[ "$PREVIOUS_DISABLESLEEP" =~ ^[0-9]+$ ]]; then
        echo "Unexpected pmset disablesleep value: $PREVIOUS_DISABLESLEEP" >&2
        exit 2
    fi

    if [[ "$REBOOT_HELD" != "1" ]]; then
        trap 'rollback best-effort || true' EXIT
    fi
fi

should_write_config=0
if [[ ! -f "$OUTPUT_DIR/validation-config.txt" || "$CONTINUE_OUTPUT" != "1" ]]; then
    should_write_config=1
elif [[ "$APPLY" == "1" ]]; then
    existing_mode="$(sed -n 's/^mode=//p' "$OUTPUT_DIR/validation-config.txt" | tail -n 1)"
    if [[ "$existing_mode" == "baseline-only" ]]; then
        should_write_config=1
    fi
fi

if [[ "$should_write_config" == "1" ]]; then
    cat >"$OUTPUT_DIR/validation-config.txt" <<EOF
caseId=${CASE_ID}
capturedAtUTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mode=$([[ "$APPLY" == "1" ]] && echo "apply" || echo "baseline-only")
testOnly=$([[ "$TEST_PMSET" == "1" ]] && echo "true" || echo "false")
rebootHeld=${REBOOT_HELD}
holdSeconds=${HOLD_SECONDS}
candidateCommand=${PMSET_BIN} disablesleep 1
previousDisablesleep=${PREVIOUS_DISABLESLEEP:-not-captured}
rollbackCommand=${PMSET_BIN} disablesleep ${PREVIOUS_DISABLESLEEP:-<previousDisablesleep>}
metadataRedacted=true
EOF
fi

if [[ ! -f "$OUTPUT_DIR/manual-result.md" || "$CONTINUE_OUTPUT" != "1" ]]; then
    cat >"$OUTPUT_DIR/manual-result.md" <<EOF
# Closed-Lid Mode Primitive Validation Result

## Matrix Case
- Case ID: ${CASE_ID:-TODO}
- macOS:
- CPU:
- Power: AC | Battery
- Display: internal-only | external-display | no-external-display
- Lid path: open | closed | reopen recovery
- Lifecycle path: normal | app-quit | crash | reboot | helper-restart

## Commands
- Applied command: \`/usr/bin/pmset disablesleep 1\`
- Prior disablesleep value:
- Rollback command: \`/usr/bin/pmset disablesleep <prior value>\`

## Required Evidence
- \`before/\`: captured before applying the candidate primitive
- \`during-applied/\`: captured while the candidate primitive is applied
- \`after-lid-window/\`: captured after the manual lid-close/reopen window
- \`after-rollback/\`: captured after rollback
- Optional \`post-reboot/\`: capture with \`AGENTWAKE_PMSET_REDACT_METADATA=1 scripts/pmset-snapshot.sh <this-dir>/post-reboot\`

## Manual Observations
- Lid-close sleep blocked: yes | no | inconclusive
- Reopen recovered cleanly: yes | no | inconclusive
- Reboot state after held primitive:
- External display state:
- Unexpected assertions/blockers:
- Conflicts with user/system power settings:

## Conclusion
- Result: pass | fail | inconclusive
- Notes:
EOF
fi

if [[ ! -d "$OUTPUT_DIR/before" || "$CONTINUE_OUTPUT" != "1" ]]; then
    snapshot "$OUTPUT_DIR/before"
fi

if [[ "$APPLY" != "1" ]]; then
    cat >"$OUTPUT_DIR/README.txt" <<EOF
Baseline-only Closed-Lid Mode primitive readiness capture written.

This run did not change power settings. To run the mutating manual lid-close
window, re-run with:

sudo scripts/closed-lid-primitive-validation.sh \\
  --output-dir "$OUTPUT_DIR" \\
  --case-id "${CASE_ID:-<case-id>}" \\
  --apply \\
  --continue \\
  --i-understand-this-changes-power-settings

The mutating mode applies /usr/bin/pmset disablesleep 1, captures evidence,
waits for the manual lid-close window, and restores the pre-run disablesleep value.
EOF
    echo "Closed-Lid Mode primitive baseline written to $OUTPUT_DIR"
    exit 0
fi

{
    echo "$ ${PMSET_BIN} disablesleep 1"
    "$PMSET_BIN" disablesleep 1
} >"$OUTPUT_DIR/applied-command.txt" 2>&1
ROLLBACK_NEEDED=1

cat >"$OUTPUT_DIR/ROLLBACK_REQUIRED.txt" <<EOF
Closed-Lid Mode primitive validation changed this setting:

Applied: ${PMSET_BIN} disablesleep 1
Restore: ${PMSET_BIN} disablesleep ${PREVIOUS_DISABLESLEEP}

After reboot-held validation, run:

sudo ${PMSET_BIN} disablesleep ${PREVIOUS_DISABLESLEEP}
AGENTWAKE_PMSET_REDACT_METADATA=1 scripts/pmset-snapshot.sh "$OUTPUT_DIR/after-rollback"
EOF

cat >"$OUTPUT_DIR/README.txt" <<EOF
Mutating Closed-Lid Mode primitive validation evidence is in progress.

Fill in manual-result.md with the physical lid-close/reopen result and run:

scripts/closed-lid-primitive-matrix-verify.sh --case-dir "$OUTPUT_DIR"
EOF

snapshot "$OUTPUT_DIR/during-applied"

if [[ "$REBOOT_HELD" == "1" ]]; then
    cat >"$OUTPUT_DIR/README.txt" <<EOF
Reboot-held Closed-Lid Mode primitive validation evidence is in progress.

Rollback instructions were written to ROLLBACK_REQUIRED.txt. After reboot,
capture post-reboot state, restore the prior disablesleep value, capture
after-rollback state, fill in manual-result.md, and run:

scripts/closed-lid-primitive-matrix-verify.sh --case-dir "$OUTPUT_DIR"
EOF

    cat <<EOF
Closed-Lid Mode primitive is applied for reboot-held validation.

The script will not roll back automatically because this run is expected to
continue through reboot. Rollback instructions were written to:
  $OUTPUT_DIR/ROLLBACK_REQUIRED.txt

After reboot:
1. Capture post-reboot state:
   AGENTWAKE_PMSET_REDACT_METADATA=1 scripts/pmset-snapshot.sh "$OUTPUT_DIR/post-reboot"
2. Restore the prior value:
   sudo ${PMSET_BIN} disablesleep ${PREVIOUS_DISABLESLEEP}
3. Capture rollback state:
   AGENTWAKE_PMSET_REDACT_METADATA=1 scripts/pmset-snapshot.sh "$OUTPUT_DIR/after-rollback"
4. Fill in:
   $OUTPUT_DIR/manual-result.md
EOF
    exit 0
fi

cat <<EOF
Closed-Lid Mode primitive is applied for ${HOLD_SECONDS}s.

Manual step:
1. Close the lid for the target scenario.
2. Reopen before or after the timer expires.
3. Record the result in:
   $OUTPUT_DIR/manual-result.md

Rollback will run automatically when the script exits.
EOF

sleep "$HOLD_SECONDS"

snapshot "$OUTPUT_DIR/after-lid-window"
rollback strict
ROLLBACK_NEEDED=0
rm -f "$OUTPUT_DIR/ROLLBACK_REQUIRED.txt"

cat >"$OUTPUT_DIR/README.txt" <<EOF
Mutating Closed-Lid Mode primitive validation evidence written.

Fill in manual-result.md with the physical lid-close/reopen result and run:

scripts/closed-lid-primitive-matrix-verify.sh --case-dir "$OUTPUT_DIR"
EOF

echo "Closed-Lid Mode primitive validation written to $OUTPUT_DIR"
