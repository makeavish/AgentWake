#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

normalize_xcode_developer_dir() {
    local candidate="$1"

    if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    if [[ -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]]; then
        printf '%s\n' "$candidate/Contents/Developer"
        return 0
    fi

    return 1
}

discover_swift_test_developer_dir() {
    local candidate
    local selected_developer_dir

    if [[ -n "${CLAWSHELL_SWIFT_TEST_DEVELOPER_DIR:-}" ]] &&
       candidate="$(normalize_xcode_developer_dir "$CLAWSHELL_SWIFT_TEST_DEVELOPER_DIR")"; then
        printf '%s\n' "$candidate"
        return 0
    fi

    if [[ -n "${DEVELOPER_DIR:-}" ]] &&
       candidate="$(normalize_xcode_developer_dir "$DEVELOPER_DIR")"; then
        printf '%s\n' "$candidate"
        return 0
    fi

    selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ "$selected_developer_dir" == *".app/Contents/Developer" ]] &&
       candidate="$(normalize_xcode_developer_dir "$selected_developer_dir")"; then
        printf '%s\n' "$candidate"
        return 0
    fi

    for candidate in /Applications/Xcode*.app; do
        [[ -d "$candidate" ]] || continue
        if candidate="$(normalize_xcode_developer_dir "$candidate")"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

swift_test_list_with_developer_dir() {
    local developer_dir="$1"
    local output_file="$2"
    local error_file="$3"

    if [[ -n "$developer_dir" ]]; then
        DEVELOPER_DIR="$developer_dir" swift test list >"$output_file" 2>"$error_file"
    else
        swift test list >"$output_file" 2>"$error_file"
    fi
}

swift_test_with_developer_dir() {
    local developer_dir="$1"

    if [[ -n "$developer_dir" ]]; then
        DEVELOPER_DIR="$developer_dir" swift test
    else
        swift test
    fi
}

swift_test_unavailable_only() {
    local error_file="$1"

    grep -q 'This toolchain does not provide Testing or XCTest' "$error_file" || return 1

    if grep -E '(^|[[:space:]])error:' "$error_file" |
       grep -v -E 'This toolchain does not provide Testing or XCTest|emit-module command failed with exit code 1|fatalError$' >/dev/null; then
        return 1
    fi

    return 0
}

echo "==> swift --version"
swift --version

echo "==> swift build"
swift build

echo "==> swift run ClawShellCoreChecks"
swift run ClawShellCoreChecks

echo "==> swift run ClawShell --smoke-test"
swift run ClawShell --smoke-test

echo "==> contract fixture slot check"
for slot in adapters cli config-patchers control-server power; do
    if [[ ! -d "Tests/ClawShellContractTests/Fixtures/$slot" ]]; then
        echo "Missing contract fixture slot directory: $slot" >&2
        exit 1
    fi
done

echo "==> shell script syntax"
for script in scripts/*.sh; do
    bash -n "$script"
done

echo "==> swift test unavailable classifier smoke"
swift_test_classifier_dir="$(mktemp -d)"
swift_test_classifier_known="$swift_test_classifier_dir/known.err"
swift_test_classifier_mixed="$swift_test_classifier_dir/mixed.err"
cat >"$swift_test_classifier_known" <<'EOF'
error: emit-module command failed with exit code 1 (use -v to see invocation)
/tmp/Test.swift:1:8: error: This toolchain does not provide Testing or XCTest. Run `swift run ClawShellCoreChecks` for portable checks.
error: fatalError
EOF
cat >"$swift_test_classifier_mixed" <<'EOF'
error: emit-module command failed with exit code 1 (use -v to see invocation)
/tmp/Test.swift:1:8: error: This toolchain does not provide Testing or XCTest. Run `swift run ClawShellCoreChecks` for portable checks.
/tmp/Other.swift:2:4: error: cannot find 'brokenSymbol' in scope
EOF
if ! swift_test_unavailable_only "$swift_test_classifier_known"; then
    echo "Swift test unavailable classifier rejected the known Testing/XCTest failure" >&2
    exit 1
fi
if swift_test_unavailable_only "$swift_test_classifier_mixed"; then
    echo "Swift test unavailable classifier accepted an unrelated compiler error" >&2
    exit 1
fi

echo "==> timed idle blocker guidance smoke"
timed_idle_guidance_dir="$(mktemp -d)"
timed_idle_guidance_error="$(mktemp)"
timed_idle_guidance_output="$timed_idle_guidance_dir/preflight.out"
trap 'rm -f "$timed_idle_guidance_error"; rm -rf "$timed_idle_guidance_dir"' EXIT
timed_idle_fake_bin="$timed_idle_guidance_dir/bin"
mkdir -p "$timed_idle_fake_bin"
cat >"$timed_idle_fake_bin/pmset" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-g batt" ]]; then
    echo "Now drawing from 'Battery Power'"
    exit 0
fi
if [[ "$*" == "-g custom" ]]; then
    cat <<'CUSTOM'
Battery Power:
 sleep 1
AC Power:
 sleep 10
CUSTOM
    exit 0
fi
if [[ "$*" == "-g assertions" ]]; then
    cat <<'ASSERTIONS'
Assertion status system-wide:
   pid 585(WindowServer): [0x1] 00:00:00 UserIsActive named: "keyboard activity"
   pid 526(powerd): [0x2] 00:01:00 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
   pid 995(sharingd): [0x3] 00:02:00 PreventUserIdleSystemSleep named: "Handoff"
   pid 61379(Slack): [0x4] 00:03:00 NoIdleSleepAssertion named: "WebRTC has active PeerConnections"
   pid 597(coreaudiod): [0x5] 00:04:00 PreventUserIdleSystemSleep named: "com.apple.audio.BuiltInMicrophoneDevice.context.preventuseridlesleep"
   pid 35118(Codex): [0x6] 00:05:00 NoIdleSleepAssertion named: "Electron"
   pid 42(ExampleApp): [0x7] 00:06:00 PreventSystemSleep named: "example"
   pid 222(Google Chrome Helper (Renderer)): [0x8] 00:07:00 NoIdleSleepAssertion named: "WebRTC has active PeerConnections"
ASSERTIONS
    exit 0
fi
echo "unexpected pmset args: $*" >&2
exit 1
EOF
chmod +x "$timed_idle_fake_bin/pmset"
if PATH="$timed_idle_fake_bin:$PATH" scripts/timed-idle-preflight.sh >"$timed_idle_guidance_output" 2>"$timed_idle_guidance_error"; then
    echo "Timed idle preflight passed despite fake non-ClawShell blockers" >&2
    cat "$timed_idle_guidance_output" >&2
    exit 1
fi
if ! grep -q '^idleSleepThresholdExceeded=true$' "$timed_idle_guidance_output" ||
   ! grep -q '^nonClawShellSleepBlockerCount=8$' "$timed_idle_guidance_output"; then
    echo "Timed idle preflight did not record expected threshold and blocker count" >&2
    cat "$timed_idle_guidance_output" >&2
    exit 1
fi
for expected in \
    'WindowServer/UserIsActive' \
    'powerd/display-on' \
    'sharingd/Handoff' \
    'Slack/WebRTC' \
    'coreaudiod/audio' \
    'Codex/Electron' \
    'ExampleApp: pause or quit' \
    'Chrome: close tabs'
do
    if ! grep -q "$expected" "$timed_idle_guidance_output"; then
        echo "Timed idle preflight guidance missing: $expected" >&2
        cat "$timed_idle_guidance_output" >&2
        exit 1
    fi
done
printf '%s\n%s\n' \
    '   pid 1(Slack): [0x1] 00:00:00 NoIdleSleepAssertion named: "WebRTC has active PeerConnections"' \
    '   pid 2(Slack): [0x2] 00:00:01 NoIdleSleepAssertion named: "WebRTC has active PeerConnections"' \
    | scripts/sleep-blocker-guidance.sh >"$timed_idle_guidance_dir/deduped.out"
if [[ "$(grep -c 'Slack/WebRTC' "$timed_idle_guidance_dir/deduped.out")" != "1" ]]; then
    echo "Sleep blocker guidance did not deduplicate repeated blocker classes" >&2
    cat "$timed_idle_guidance_dir/deduped.out" >&2
    exit 1
fi

echo "==> bag mode primitive harness smoke"
bag_mode_smoke_dir="$(mktemp -d)"
bag_mode_smoke_error="$(mktemp)"
test_list_output=""
test_list_error=""
temperature_validation_before=""
trap '[[ -n "$test_list_output" ]] && rm -f "$test_list_output"; [[ -n "$test_list_error" ]] && rm -f "$test_list_error"; [[ -n "$temperature_validation_before" ]] && rm -f "$temperature_validation_before"; rm -f "$timed_idle_guidance_error" "$bag_mode_smoke_error"; rm -rf "$timed_idle_guidance_dir" "$bag_mode_smoke_dir"' EXIT

if scripts/bag-mode-primitive-validation.sh --output-dir "$bag_mode_smoke_dir/missing-ack" --apply >"$bag_mode_smoke_error" 2>&1; then
    echo "Bag Mode primitive harness allowed --apply without acknowledgement" >&2
    exit 1
fi
if ! grep -q -- "--apply requires --i-understand-this-changes-power-settings" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

scripts/bag-mode-primitive-validation.sh --output-dir "$bag_mode_smoke_dir/baseline" --case-id validate-smoke >/dev/null
before_mtime="$(stat -f %m "$bag_mode_smoke_dir/baseline/before/metadata.txt")"

for required_file in validation-config.txt manual-result.md README.txt before/metadata.txt; do
    if [[ ! -f "$bag_mode_smoke_dir/baseline/$required_file" ]]; then
        echo "Bag Mode primitive harness did not write expected file: $required_file" >&2
        exit 1
    fi
done

if ! grep -q '^metadataRedacted=true$' "$bag_mode_smoke_dir/baseline/validation-config.txt"; then
    echo "Bag Mode primitive harness did not record redacted metadata mode" >&2
    exit 1
fi
if grep -q '^host=' "$bag_mode_smoke_dir/baseline/before/metadata.txt" &&
   ! grep -q '^host=<redacted>$' "$bag_mode_smoke_dir/baseline/before/metadata.txt"; then
    echo "Bag Mode primitive harness did not redact host metadata" >&2
    exit 1
fi
if scripts/bag-mode-primitive-validation.sh --output-dir "$bag_mode_smoke_dir/baseline" --case-id validate-smoke >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive harness overwrote a non-empty evidence directory without --continue" >&2
    exit 1
fi
if ! grep -q 'Output directory is not empty' "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
scripts/bag-mode-primitive-validation.sh --output-dir "$bag_mode_smoke_dir/baseline" --case-id validate-smoke --continue >/dev/null
after_mtime="$(stat -f %m "$bag_mode_smoke_dir/baseline/before/metadata.txt")"
if [[ "$before_mtime" != "$after_mtime" ]]; then
    echo "Bag Mode primitive harness rewrote the original before snapshot during --continue" >&2
    exit 1
fi

bag_mode_apply_bin="$bag_mode_smoke_dir/apply-bin"
mkdir -p "$bag_mode_apply_bin"
cat >"$bag_mode_apply_bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -u) echo 0 ;;
    -un) echo "<redacted>" ;;
    *) /usr/bin/id "$@" ;;
esac
EOF
cat >"$bag_mode_apply_bin/pmset" <<'EOF'
#!/usr/bin/env bash
state_file="${CLAWSHELL_FAKE_PMSET_STATE:?}"
log_file="${CLAWSHELL_FAKE_PMSET_LOG:?}"
printf '%s\n' "$*" >>"$log_file"
if [[ "${1:-}" == "-g" && "${2:-}" == "custom" ]]; then
    printf 'Battery Power:\n'
    printf ' disablesleep %s\n' "$(cat "$state_file")"
    exit 0
fi
if [[ "${1:-}" == "-g" ]]; then
    printf 'fake pmset %s output\n' "${2:-}"
    exit 0
fi
if [[ "${1:-}" == "disablesleep" && "${2:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$2" >"$state_file"
    printf 'set disablesleep %s\n' "$2"
    exit 0
fi
printf 'unexpected pmset args: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$bag_mode_apply_bin/id" "$bag_mode_apply_bin/pmset"

bag_mode_apply_transition="$bag_mode_smoke_dir/apply-transition"
bag_mode_apply_state="$bag_mode_smoke_dir/apply-state"
bag_mode_apply_log="$bag_mode_smoke_dir/apply-commands.log"
printf '2\n' >"$bag_mode_apply_state"
touch "$bag_mode_apply_log"
scripts/bag-mode-primitive-validation.sh \
    --output-dir "$bag_mode_apply_transition" \
    --case-id validate-apply-transition >/dev/null
PATH="$bag_mode_apply_bin:$PATH" \
CLAWSHELL_BAG_MODE_PRIMITIVE_TEST_PMSET=1 \
CLAWSHELL_PMSET_BIN="$bag_mode_apply_bin/pmset" \
CLAWSHELL_FAKE_PMSET_STATE="$bag_mode_apply_state" \
CLAWSHELL_FAKE_PMSET_LOG="$bag_mode_apply_log" \
    scripts/bag-mode-primitive-validation.sh \
        --output-dir "$bag_mode_apply_transition" \
        --case-id validate-apply-transition \
        --hold-seconds 1 \
        --apply \
        --continue \
        --i-understand-this-changes-power-settings >/dev/null
if ! grep -q '^mode=apply$' "$bag_mode_apply_transition/validation-config.txt"; then
    echo "Bag Mode primitive harness did not transition baseline config to apply mode" >&2
    exit 1
fi
if ! grep -q '^testOnly=true$' "$bag_mode_apply_transition/validation-config.txt"; then
    echo "Bag Mode primitive harness did not mark fake pmset transition as test-only" >&2
    exit 1
fi
if ! grep -q '^previousDisablesleep=2$' "$bag_mode_apply_transition/validation-config.txt"; then
    echo "Bag Mode primitive harness did not record previous disablesleep value during apply transition" >&2
    exit 1
fi
if ! grep -q '^rollbackCommand=.*/pmset disablesleep 2$' "$bag_mode_apply_transition/validation-config.txt"; then
    echo "Bag Mode primitive harness did not record rollback command during apply transition" >&2
    exit 1
fi
if ! grep -q 'disablesleep 1' "$bag_mode_apply_transition/applied-command.txt"; then
    echo "Bag Mode primitive harness did not apply disablesleep 1 during apply transition" >&2
    exit 1
fi
if ! grep -q 'disablesleep 2' "$bag_mode_apply_transition/rollback-command.txt"; then
    echo "Bag Mode primitive harness did not roll back to the captured prior value during apply transition" >&2
    exit 1
fi
if [[ "$(cat "$bag_mode_apply_state")" != "2" ]]; then
    echo "Bag Mode primitive harness fake pmset state did not return to captured prior value" >&2
    exit 1
fi
if ! grep -q '^disablesleep 1$' "$bag_mode_apply_log" ||
   ! grep -q '^disablesleep 2$' "$bag_mode_apply_log"; then
    echo "Bag Mode primitive harness did not log distinct apply and rollback disablesleep commands" >&2
    cat "$bag_mode_apply_log" >&2
    exit 1
fi
if [[ ! -f "$bag_mode_apply_transition/during-applied/pmset-custom.txt" ||
      ! -f "$bag_mode_apply_transition/after-lid-window/pmset-custom.txt" ||
      ! -f "$bag_mode_apply_transition/after-rollback/pmset-custom.txt" ]]; then
    echo "Bag Mode primitive harness did not write apply transition snapshots" >&2
    exit 1
fi
if [[ -f "$bag_mode_apply_transition/ROLLBACK_REQUIRED.txt" ]]; then
    echo "Bag Mode primitive harness left rollback marker after successful non-reboot apply transition" >&2
    exit 1
fi
if grep -q 'Baseline-only' "$bag_mode_apply_transition/README.txt"; then
    echo "Bag Mode primitive harness left stale baseline README after apply transition" >&2
    exit 1
fi

bag_mode_matrix_case="$bag_mode_smoke_dir/matrix/validate-smoke"
mkdir -p \
    "$bag_mode_matrix_case/before" \
    "$bag_mode_matrix_case/during-applied" \
    "$bag_mode_matrix_case/after-lid-window" \
    "$bag_mode_matrix_case/after-rollback"
cat >"$bag_mode_matrix_case/validation-config.txt" <<'EOF'
caseId=validate-smoke
capturedAtUTC=2026-05-12T00:00:00Z
mode=apply
testOnly=false
rebootHeld=0
holdSeconds=1
candidateCommand=/usr/bin/pmset disablesleep 1
previousDisablesleep=0
rollbackCommand=/usr/bin/pmset disablesleep 0
metadataRedacted=true
EOF
cat >"$bag_mode_matrix_case/manual-result.md" <<'EOF'
# Bag Mode Primitive Validation Result

## Matrix Case
- Case ID: validate-smoke
- macOS: 15.0
- CPU: Apple Silicon
- Power: Battery
- Display: internal-only
- Lid path: reopen recovery
- Lifecycle path: normal

## Commands
- Applied command: `/usr/bin/pmset disablesleep 1`
- Prior disablesleep value: 0
- Rollback command: `/usr/bin/pmset disablesleep 0`

## Manual Observations
- Lid-close sleep blocked: inconclusive
- Reopen recovered cleanly: yes
- Reboot state after held primitive: N/A - non-reboot case

## Conclusion
- Result: inconclusive
EOF
for snapshot_dir in before during-applied after-lid-window after-rollback; do
    cat >"$bag_mode_matrix_case/$snapshot_dir/metadata.txt" <<'EOF'
capturedAtUTC=2026-05-12T00:00:00Z
host=<redacted>
user=<redacted>
EOF
    printf '$ pmset -g custom\nBattery Power:\n' >"$bag_mode_matrix_case/$snapshot_dir/pmset-custom.txt"
    printf '$ pmset -g assertions\nAssertion status system-wide:\n' >"$bag_mode_matrix_case/$snapshot_dir/pmset-assertions.txt"
    printf '$ ioreg -r -c IOPMPowerSource -a\n<plist version=\"1.0\">\n' >"$bag_mode_matrix_case/$snapshot_dir/ioreg-power.txt"
done
scripts/bag-mode-primitive-matrix-verify.sh --evidence-root "$bag_mode_smoke_dir/matrix" >/dev/null
cat >"$bag_mode_smoke_dir/matrix/matrix-manifest.tsv" <<'EOF'
caseId	status	evidenceDir	naReason
validate-smoke	evidence	validate-smoke	evidence attached
macos-13-intel-deferred	deferred		Intel support not in current local hardware scope
external-display-na	n/a		No external display physically available in this smoke
EOF
scripts/bag-mode-primitive-matrix-verify.sh --manifest "$bag_mode_smoke_dir/matrix/matrix-manifest.tsv" >/dev/null
cat >"$bag_mode_smoke_dir/matrix/all-deferred-manifest.tsv" <<'EOF'
caseId	status	evidenceDir	naReason
macos-13-intel	deferred		No Intel host available for this smoke
external-display	n/a		No external display physically available in this smoke
EOF
if scripts/bag-mode-primitive-matrix-verify.sh --manifest "$bag_mode_smoke_dir/matrix/all-deferred-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted a manifest with no evidence rows" >&2
    exit 1
fi
if ! grep -q "at least one evidence row" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
bag_mode_matrix_scaffold="$bag_mode_smoke_dir/matrix-scaffold"
scripts/bag-mode-primitive-matrix-scaffold.sh --output-dir "$bag_mode_matrix_scaffold" >/dev/null
for required_file in matrix-manifest.tsv README.md scaffold-config.txt; do
    if [[ ! -f "$bag_mode_matrix_scaffold/$required_file" ]]; then
        echo "Bag Mode primitive matrix scaffold did not write expected file: $required_file" >&2
        exit 1
    fi
done
if ! grep -q '^scaffoldFormat=bag-mode-primitive-matrix-scaffold-v1$' "$bag_mode_matrix_scaffold/scaffold-config.txt"; then
    echo "Bag Mode primitive matrix scaffold did not record expected scaffold format" >&2
    exit 1
fi
if scripts/bag-mode-primitive-matrix-verify.sh --manifest "$bag_mode_matrix_scaffold/matrix-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted the TODO scaffold manifest" >&2
    exit 1
fi
if ! grep -q "status must be evidence, n/a, or deferred" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
bag_mode_matrix_test_only="$bag_mode_smoke_dir/matrix-test-only"
cp -R "$bag_mode_matrix_case" "$bag_mode_matrix_test_only"
sed -i '' 's/^testOnly=false$/testOnly=true/' "$bag_mode_matrix_test_only/validation-config.txt"
if scripts/bag-mode-primitive-matrix-verify.sh --case-dir "$bag_mode_matrix_test_only" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted test-only pmset evidence" >&2
    exit 1
fi
if ! grep -q "testOnly must be false" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
bag_mode_matrix_bad_rollback="$bag_mode_smoke_dir/matrix-bad-rollback"
cp -R "$bag_mode_matrix_case" "$bag_mode_matrix_bad_rollback"
sed -i '' 's/^previousDisablesleep=0$/previousDisablesleep=1/' "$bag_mode_matrix_bad_rollback/validation-config.txt"
if scripts/bag-mode-primitive-matrix-verify.sh --case-dir "$bag_mode_matrix_bad_rollback" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted rollback command that does not restore previousDisablesleep" >&2
    exit 1
fi
if ! grep -q "rollbackCommand must restore previousDisablesleep" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
bag_mode_matrix_bad_manual_rollback="$bag_mode_smoke_dir/matrix-bad-manual-rollback"
cp -R "$bag_mode_matrix_case" "$bag_mode_matrix_bad_manual_rollback"
sed -i '' 's/^previousDisablesleep=0$/previousDisablesleep=1/' "$bag_mode_matrix_bad_manual_rollback/validation-config.txt"
sed -i '' 's#^rollbackCommand=/usr/bin/pmset disablesleep 0$#rollbackCommand=/usr/bin/pmset disablesleep 1#' "$bag_mode_matrix_bad_manual_rollback/validation-config.txt"
sed -i '' 's/- Prior disablesleep value: 0/- Prior disablesleep value: 1/' "$bag_mode_matrix_bad_manual_rollback/manual-result.md"
sed -i '' 's#- Rollback command: `/usr/bin/pmset disablesleep 0`#- Rollback command: `/usr/bin/pmset disablesleep 10`#' "$bag_mode_matrix_bad_manual_rollback/manual-result.md"
if scripts/bag-mode-primitive-matrix-verify.sh --case-dir "$bag_mode_matrix_bad_manual_rollback" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted manual rollback command with numeric-prefix mismatch" >&2
    exit 1
fi
if ! grep -q "Rollback command must restore the prior disablesleep value" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
sed -i '' 's/- Result: inconclusive/- Result: pass | fail | inconclusive/' "$bag_mode_matrix_case/manual-result.md"
if scripts/bag-mode-primitive-matrix-verify.sh --case-dir "$bag_mode_matrix_case" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted a placeholder result" >&2
    exit 1
fi
if ! grep -q "Result" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
sed -i '' 's/- Result: pass | fail | inconclusive/- Result: inconclusive/' "$bag_mode_matrix_case/manual-result.md"
: >"$bag_mode_matrix_case/after-rollback/pmset-custom.txt"
if scripts/bag-mode-primitive-matrix-verify.sh --case-dir "$bag_mode_matrix_case" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted empty snapshot output" >&2
    exit 1
fi
if ! grep -q "empty file" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
echo '$ pmset -g custom' >"$bag_mode_matrix_case/after-rollback/pmset-custom.txt"
if scripts/bag-mode-primitive-matrix-verify.sh --case-dir "$bag_mode_matrix_case" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted header-only snapshot output" >&2
    exit 1
fi
if ! grep -q "no captured command body" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
printf '$ pmset -g custom\nBattery Power:\n' >"$bag_mode_matrix_case/after-rollback/pmset-custom.txt"
sed -i '' 's/- macOS: 15.0/- macOS: banana/' "$bag_mode_matrix_case/manual-result.md"
if scripts/bag-mode-primitive-matrix-verify.sh --case-dir "$bag_mode_matrix_case" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted invalid macOS value" >&2
    exit 1
fi
if ! grep -q "macOS" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
sed -i '' 's/- macOS: banana/- macOS: 15.0/' "$bag_mode_matrix_case/manual-result.md"
mkdir -p "$bag_mode_matrix_case/post-reboot"
cat >"$bag_mode_matrix_case/post-reboot/metadata.txt" <<'EOF'
capturedAtUTC=2026-05-12T00:00:00Z
host=<redacted>
user=<redacted>
EOF
printf '$ pmset -g custom\nBattery Power:\n' >"$bag_mode_matrix_case/post-reboot/pmset-custom.txt"
printf '$ pmset -g assertions\nAssertion status system-wide:\n' >"$bag_mode_matrix_case/post-reboot/pmset-assertions.txt"
printf '$ ioreg -r -c IOPMPowerSource -a\n<plist version="1.0">\n' >"$bag_mode_matrix_case/post-reboot/ioreg-power.txt"
sed -i '' 's/rebootHeld=0/rebootHeld=1/' "$bag_mode_matrix_case/validation-config.txt"
sed -i '' 's/- Lifecycle path: normal/- Lifecycle path: reboot/' "$bag_mode_matrix_case/manual-result.md"
if scripts/bag-mode-primitive-matrix-verify.sh --case-dir "$bag_mode_matrix_case" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted N/A reboot state for reboot-held case" >&2
    exit 1
fi
if ! grep -q "reboot-held" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
sed -i '' 's/rebootHeld=1/rebootHeld=0/' "$bag_mode_matrix_case/validation-config.txt"
sed -i '' 's/- Lifecycle path: reboot/- Lifecycle path: normal/' "$bag_mode_matrix_case/manual-result.md"
sed -i '' 's/No external display physically available in this smoke/TODO/' "$bag_mode_smoke_dir/matrix/matrix-manifest.tsv"
if scripts/bag-mode-primitive-matrix-verify.sh --manifest "$bag_mode_smoke_dir/matrix/matrix-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted placeholder N/A reason" >&2
    exit 1
fi
if ! grep -q "external-display-na" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

echo "==> temperature provider harness smoke"
temperature_smoke_dir="$bag_mode_smoke_dir/temperature-provider"
scripts/temperature-provider-validation.sh --output-dir "$temperature_smoke_dir" >/dev/null
for required_file in \
    metadata.txt \
    processinfo-thermal-state.txt \
    processinfo-thermal-state.status \
    pmset-therm.txt \
    pmset-therm.status \
    powermetrics-thermal.txt \
    powermetrics-thermal.status \
    battery-temperature.txt \
    battery-temperature.status \
    validation-config.txt \
    summary-computed.md \
    summary.md
do
    if [[ ! -f "$temperature_smoke_dir/$required_file" ]]; then
        echo "Temperature provider harness did not write expected file: $required_file" >&2
        exit 1
    fi
done
if ! grep -q '^bagModeTemperatureProviderReady=false$' "$temperature_smoke_dir/validation-config.txt"; then
    echo "Temperature provider harness should not mark Bag Mode temperature provider ready" >&2
    exit 1
fi
if ! grep -q '^candidateSelected=none$' "$temperature_smoke_dir/validation-config.txt"; then
    echo "Temperature provider harness should keep provider selection explicit" >&2
    exit 1
fi
if ! grep -q '^metadataRedacted=true$' "$temperature_smoke_dir/metadata.txt"; then
    echo "Temperature provider harness did not record redacted metadata mode" >&2
    exit 1
fi
if grep -Eq '^(host|user)=' "$temperature_smoke_dir/metadata.txt"; then
    echo "Temperature provider harness wrote host/user metadata" >&2
    exit 1
fi

temperature_validation_before="$(mktemp)"
cp "$temperature_smoke_dir/validation-config.txt" "$temperature_validation_before"
scripts/temperature-provider-validation.sh --output-dir "$temperature_smoke_dir" --continue >/dev/null
if ! cmp -s "$temperature_validation_before" "$temperature_smoke_dir/validation-config.txt"; then
    echo "Temperature provider harness rewrote validation config during --continue" >&2
    exit 1
fi

if scripts/temperature-provider-validation.sh --output-dir "$temperature_smoke_dir" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider harness overwrote a non-empty evidence directory without --continue" >&2
    exit 1
fi
if ! grep -q 'Output directory is not empty' "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_file_output="$bag_mode_smoke_dir/temperature-output-file"
touch "$temperature_file_output"
if scripts/temperature-provider-validation.sh --output-dir "$temperature_file_output" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider harness accepted an output path that is not a directory" >&2
    exit 1
fi
if ! grep -q 'not a directory' "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_bad_env_dir="$bag_mode_smoke_dir/temperature-bad-env"
if CLAWSHELL_TEMPERATURE_PROVIDER_TIMEOUT_SECONDS=abc \
    scripts/temperature-provider-validation.sh --output-dir "$temperature_bad_env_dir" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider harness accepted an invalid timeout value" >&2
    exit 1
fi
if [[ -e "$temperature_bad_env_dir" ]]; then
    echo "Temperature provider harness created evidence for an invalid timeout value" >&2
    exit 1
fi

temperature_timeout_bin="$bag_mode_smoke_dir/temperature-timeout-fake"
mkdir -p "$temperature_timeout_bin"
cat >"$temperature_timeout_bin/pmset" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
chmod +x "$temperature_timeout_bin/pmset"
temperature_timeout_dir="$bag_mode_smoke_dir/temperature-timeout"
CLAWSHELL_TEMPERATURE_PROVIDER_TIMEOUT_SECONDS=1 \
PATH="$temperature_timeout_bin:$PATH" scripts/temperature-provider-validation.sh --output-dir "$temperature_timeout_dir" >/dev/null
if ! grep -q '^timedOut=true$' "$temperature_timeout_dir/pmset-therm.status"; then
    echo "Temperature provider harness did not record timeout for hanging pmset command" >&2
    cat "$temperature_timeout_dir/pmset-therm.status" >&2
    exit 1
fi

temperature_fake_bin="$bag_mode_smoke_dir/temperature-fakes"
mkdir -p "$temperature_fake_bin"
cat >"$temperature_fake_bin/swift" <<'EOF'
#!/usr/bin/env bash
echo "thermalState=fair"
EOF
cat >"$temperature_fake_bin/pmset" <<'EOF'
#!/usr/bin/env bash
echo "CPU die temperature: 42 C"
EOF
cat >"$temperature_fake_bin/powermetrics" <<'EOF'
#!/usr/bin/env bash
echo "thermal sampler available"
EOF
cat >"$temperature_fake_bin/ioreg" <<'EOF'
#!/usr/bin/env bash
now="$(date +%s)"
cat <<EOT
      "UpdateTime" = $now
      "Temperature" = 3046
      "VirtualTemperature" = 3139
EOT
EOF
chmod +x "$temperature_fake_bin/swift" "$temperature_fake_bin/pmset" "$temperature_fake_bin/powermetrics" "$temperature_fake_bin/ioreg"

temperature_fake_dir="$bag_mode_smoke_dir/temperature-fake"
CLAWSHELL_TEMPERATURE_PROVIDER_TIMEOUT_SECONDS=5 \
CLAWSHELL_TEMPERATURE_PROVIDER_PROCESSINFO_TIMEOUT_SECONDS=5 \
PATH="$temperature_fake_bin:$PATH" scripts/temperature-provider-validation.sh --output-dir "$temperature_fake_dir" >/dev/null
if ! grep -q '^processInfoThermalState=fair$' "$temperature_fake_dir/validation-config.txt"; then
    echo "Temperature provider harness did not parse fake ProcessInfo output" >&2
    exit 1
fi
if ! grep -q '^pmsetCurrentNumericTemperature=true$' "$temperature_fake_dir/validation-config.txt"; then
    echo "Temperature provider harness did not parse fake pmset numeric output" >&2
    exit 1
fi
if ! grep -q '^powermetricsPermissionState=availableWithoutRoot$' "$temperature_fake_dir/validation-config.txt"; then
    echo "Temperature provider harness did not classify fake powermetrics success" >&2
    exit 1
fi
if ! grep -q '^batteryFreshWithin10Seconds=true$' "$temperature_fake_dir/validation-config.txt"; then
    echo "Temperature provider harness did not parse fake battery freshness" >&2
    exit 1
fi

echo "==> temperature helper readiness harness smoke"
temperature_helper_readiness_dir="$bag_mode_smoke_dir/temperature-helper-readiness"
scripts/temperature-provider-helper-readiness.sh --output-dir "$temperature_helper_readiness_dir" >/dev/null
for required_file in \
    sudo-noninteractive.txt \
    sudo-noninteractive.status \
    pmset-battery.txt \
    pmset-battery.status \
    powermetrics-helper-sample.txt \
    powermetrics-helper-sample.status \
    validation-config.txt \
    summary.md
do
    if [[ ! -f "$temperature_helper_readiness_dir/$required_file" ]]; then
        echo "Temperature helper readiness harness did not write expected file: $required_file" >&2
        exit 1
    fi
done
if ! grep -q '^metadataRedacted=true$' "$temperature_helper_readiness_dir/validation-config.txt"; then
    echo "Temperature helper readiness harness did not record redacted metadata mode" >&2
    exit 1
fi
if ! grep -q '^providerProofReady=false$' "$temperature_helper_readiness_dir/validation-config.txt"; then
    echo "Temperature helper readiness harness overclaimed provider proof readiness" >&2
    exit 1
fi

temperature_helper_file_output="$bag_mode_smoke_dir/temperature-helper-output-file"
touch "$temperature_helper_file_output"
if scripts/temperature-provider-helper-readiness.sh --output-dir "$temperature_helper_file_output" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature helper readiness harness accepted an output path that is not a directory" >&2
    exit 1
fi
if ! grep -q 'not a directory' "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_helper_non_empty_dir="$bag_mode_smoke_dir/temperature-helper-non-empty"
mkdir -p "$temperature_helper_non_empty_dir"
touch "$temperature_helper_non_empty_dir/existing"
if scripts/temperature-provider-helper-readiness.sh --output-dir "$temperature_helper_non_empty_dir" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature helper readiness harness overwrote a non-empty evidence directory" >&2
    exit 1
fi
if ! grep -q 'Output directory is not empty' "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_helper_bad_env_dir="$bag_mode_smoke_dir/temperature-helper-bad-env"
if CLAWSHELL_TEMPERATURE_HELPER_READINESS_TIMEOUT_SECONDS=abc \
    scripts/temperature-provider-helper-readiness.sh --output-dir "$temperature_helper_bad_env_dir" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature helper readiness harness accepted an invalid timeout value" >&2
    exit 1
fi
if [[ -e "$temperature_helper_bad_env_dir" ]]; then
    echo "Temperature helper readiness harness created evidence for an invalid timeout value" >&2
    exit 1
fi

temperature_helper_timeout_bin="$bag_mode_smoke_dir/temperature-helper-timeout-fakes"
mkdir -p "$temperature_helper_timeout_bin"
cat >"$temperature_helper_timeout_bin/pmset" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-g batt" ]]; then
    echo "Now drawing from 'Battery Power'"
    exit 0
fi
exit 1
EOF
cat >"$temperature_helper_timeout_bin/powermetrics" <<'EOF'
#!/usr/bin/env bash
sleep 10
EOF
cat >"$temperature_helper_timeout_bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" != "-n" ]]; then
    echo "sudo: refusing promptable invocation" >&2
    exit 99
fi
shift
if [[ "${1:-}" == "true" ]]; then
    exit 0
fi
"$@"
EOF
chmod +x "$temperature_helper_timeout_bin/pmset" "$temperature_helper_timeout_bin/powermetrics" "$temperature_helper_timeout_bin/sudo"
temperature_helper_timeout_dir="$bag_mode_smoke_dir/temperature-helper-timeout"
CLAWSHELL_TEMPERATURE_HELPER_READINESS_TIMEOUT_SECONDS=1 \
PATH="$temperature_helper_timeout_bin:$PATH" \
    scripts/temperature-provider-helper-readiness.sh --output-dir "$temperature_helper_timeout_dir" >/dev/null
if ! grep -q '^timedOut=true$' "$temperature_helper_timeout_dir/powermetrics-helper-sample.status"; then
    echo "Temperature helper readiness harness did not record timeout for hanging powermetrics command" >&2
    cat "$temperature_helper_timeout_dir/powermetrics-helper-sample.status" >&2
    exit 1
fi
if ! grep -q '^powermetricsHelperPermissionState=timedOut$' "$temperature_helper_timeout_dir/validation-config.txt"; then
    echo "Temperature helper readiness harness did not classify timed-out powermetrics sampling" >&2
    cat "$temperature_helper_timeout_dir/validation-config.txt" >&2
    exit 1
fi

temperature_helper_fake_bin="$bag_mode_smoke_dir/temperature-helper-fakes"
mkdir -p "$temperature_helper_fake_bin"
cat >"$temperature_helper_fake_bin/pmset" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-g batt" ]]; then
    echo "Now drawing from 'Battery Power'"
    echo " -InternalBattery-0 (id=1234567)"
    exit 0
fi
exit 1
EOF
cat >"$temperature_helper_fake_bin/powermetrics" <<'EOF'
#!/usr/bin/env bash
echo "CPU die temperature: 42 C"
EOF
cat >"$temperature_helper_fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" != "-n" ]]; then
    echo "sudo: refusing promptable invocation" >&2
    exit 99
fi
shift
echo "sudo: a password is required" >&2
exit 1
EOF
chmod +x "$temperature_helper_fake_bin/pmset" "$temperature_helper_fake_bin/powermetrics" "$temperature_helper_fake_bin/sudo"

temperature_helper_password_dir="$bag_mode_smoke_dir/temperature-helper-password-required"
CLAWSHELL_TEMPERATURE_HELPER_READINESS_TIMEOUT_SECONDS=5 \
PATH="$temperature_helper_fake_bin:$PATH" \
    scripts/temperature-provider-helper-readiness.sh --output-dir "$temperature_helper_password_dir" >/dev/null
if ! grep -q '^sudoNonInteractiveAvailable=false$' "$temperature_helper_password_dir/validation-config.txt"; then
    echo "Temperature helper readiness harness did not record unavailable non-interactive sudo" >&2
    exit 1
fi
if ! grep -q '^powermetricsHelperPermissionState=sudoPasswordRequired$' "$temperature_helper_password_dir/validation-config.txt"; then
    echo "Temperature helper readiness harness did not classify sudo password requirement" >&2
    cat "$temperature_helper_password_dir/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^helperSamplingCandidateAvailable=false$' "$temperature_helper_password_dir/validation-config.txt"; then
    echo "Temperature helper readiness harness accepted password-gated sampling as candidate-ready" >&2
    exit 1
fi
if grep -Eq 'id=[0-9]' "$temperature_helper_password_dir/pmset-battery.txt"; then
    echo "Temperature helper readiness harness left raw battery identifier in pmset output" >&2
    cat "$temperature_helper_password_dir/pmset-battery.txt" >&2
    exit 1
fi
if ! grep -q 'id=<redacted>' "$temperature_helper_password_dir/pmset-battery.txt"; then
    echo "Temperature helper readiness harness did not preserve redacted battery identifier marker" >&2
    cat "$temperature_helper_password_dir/pmset-battery.txt" >&2
    exit 1
fi

cat >"$temperature_helper_fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" != "-n" ]]; then
    echo "sudo: refusing promptable invocation" >&2
    exit 99
fi
shift
if [[ "${1:-}" == "true" ]]; then
    exit 0
fi
"$@"
EOF
chmod +x "$temperature_helper_fake_bin/sudo"

temperature_helper_available_dir="$bag_mode_smoke_dir/temperature-helper-available"
CLAWSHELL_TEMPERATURE_HELPER_READINESS_TIMEOUT_SECONDS=5 \
PATH="$temperature_helper_fake_bin:$PATH" \
    scripts/temperature-provider-helper-readiness.sh --output-dir "$temperature_helper_available_dir" >/dev/null
if ! grep -q '^sudoNonInteractiveAvailable=true$' "$temperature_helper_available_dir/validation-config.txt"; then
    echo "Temperature helper readiness harness did not record available non-interactive sudo" >&2
    exit 1
fi
if ! grep -q '^powermetricsHelperPermissionState=availableWithPasswordlessSudo$' "$temperature_helper_available_dir/validation-config.txt"; then
    echo "Temperature helper readiness harness did not classify passwordless helper-equivalent sampling" >&2
    cat "$temperature_helper_available_dir/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^numericTemperatureOutput=true$' "$temperature_helper_available_dir/validation-config.txt"; then
    echo "Temperature helper readiness harness did not detect fake numeric output" >&2
    exit 1
fi
if ! grep -q '^helperSamplingCandidateAvailable=true$' "$temperature_helper_available_dir/validation-config.txt"; then
    echo "Temperature helper readiness harness did not mark fake helper sampling as candidate-ready" >&2
    exit 1
fi
if ! grep -q '^providerProofReady=false$' "$temperature_helper_available_dir/validation-config.txt"; then
    echo "Temperature helper readiness harness overclaimed full provider proof for fake sampling" >&2
    exit 1
fi

echo "==> temperature provider proof verifier smoke"
temperature_proof_dir="$bag_mode_smoke_dir/temperature-proof"
temperature_proof_manifest="$temperature_proof_dir/provider-manifest.tsv"
temperature_proof_evidence_dir="$temperature_proof_dir/evidence"
mkdir -p "$temperature_proof_evidence_dir"
cat >"$temperature_proof_dir/validation-config.txt" <<'EOF'
evidenceFormat=temperature-provider-proof-v1
metadataRedacted=true
macOSVersion=15.0
cpu=Apple Silicon
hardwareClass=MacBook
providerSource=powermetrics
helperOwned=true
processInfoSupplementalOnly=true
numericCutoffSource=true
noUserVisiblePrompts=true
freshnessMaxAgeSeconds=10
activeCadenceSeconds=5
idleCadenceSeconds=30
timeoutSeconds=1
closedBagCoverage=requires-combined-signals
failClosedContract=covered
result=inconclusive
EOF
cat >"$temperature_proof_dir/manual-result.md" <<'EOF'
# Temperature Provider Proof Result

## Provider Case
- Case ID: validate-temperature-proof
- Provider source: powermetrics
- Helper-owned provider: yes
- Numeric cutoff source: yes
- No user-visible prompts: yes
- ProcessInfo role: supplemental-only

## Sampling
- Freshest reading age seconds: 4
- Active cadence seconds: 5
- Idle cadence seconds: 30
- Timeout seconds: 1

## Coverage
- Closed-bag coverage: requires-combined-signals
- Fail-closed cases recorded: yes

## Conclusion
- Result: inconclusive
EOF
temperature_proof_required_checks=(
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
)
{
    printf 'checkId\tstatus\tevidencePath\tnote\n'
    for check_id in "${temperature_proof_required_checks[@]}"; do
        printf '$ %s\ncaptured temperature provider proof output for %s\n' "$check_id" "$check_id" >"$temperature_proof_evidence_dir/$check_id.txt"
        printf '%s\tevidence\tevidence/%s.txt\tevidence attached\n' "$check_id" "$check_id"
    done
    printf 'combined-sensor-signal\tevidence\tevidence/combined-sensor-signal.txt\tcombined signal evidence attached\n'
    printf 'provider-update-or-restart\tn/a\t\tProvider restart not exercised in this smoke\n'
} >"$temperature_proof_manifest"
printf '$ combined-sensor-signal\ncaptured combined thermal pressure and numeric data\n' >"$temperature_proof_evidence_dir/combined-sensor-signal.txt"
scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_manifest" >/dev/null

temperature_proof_scaffold="$bag_mode_smoke_dir/temperature-proof-scaffold"
scripts/temperature-provider-proof-scaffold.sh --output-dir "$temperature_proof_scaffold" >/dev/null
for required_file in provider-manifest.tsv README.md scaffold-config.txt; do
    if [[ ! -f "$temperature_proof_scaffold/$required_file" ]]; then
        echo "Temperature provider proof scaffold did not write expected file: $required_file" >&2
        exit 1
    fi
done
if [[ -f "$temperature_proof_scaffold/validation-config.txt" || -f "$temperature_proof_scaffold/manual-result.md" ]]; then
    echo "Temperature provider proof scaffold wrote evidence-shaped files before real capture" >&2
    exit 1
fi
if ! grep -q '^scaffoldFormat=temperature-provider-proof-scaffold-v1$' "$temperature_proof_scaffold/scaffold-config.txt"; then
    echo "Temperature provider proof scaffold did not record expected scaffold format" >&2
    exit 1
fi
if [[ "$(head -n 1 "$temperature_proof_scaffold/provider-manifest.tsv")" != $'checkId\tstatus\tevidencePath\tnote' ]]; then
    echo "Temperature provider proof scaffold wrote an unexpected manifest header" >&2
    cat "$temperature_proof_scaffold/provider-manifest.tsv" >&2
    exit 1
fi
if ! awk -F '\t' 'NR == 1 { next } NF != 4 { exit 1 }' "$temperature_proof_scaffold/provider-manifest.tsv"; then
    echo "Temperature provider proof scaffold wrote a manifest row with an unexpected field count" >&2
    cat "$temperature_proof_scaffold/provider-manifest.tsv" >&2
    exit 1
fi
temperature_proof_scaffold_expected_ids="$bag_mode_smoke_dir/temperature-proof-scaffold-expected-ids"
temperature_proof_scaffold_actual_ids="$bag_mode_smoke_dir/temperature-proof-scaffold-actual-ids"
{
    for check_id in "${temperature_proof_required_checks[@]}"; do
        printf '%s\n' "$check_id"
    done
    printf '%s\n' "combined-sensor-signal"
    printf '%s\n' "provider-update-or-restart"
} | sort >"$temperature_proof_scaffold_expected_ids"
tail -n +2 "$temperature_proof_scaffold/provider-manifest.tsv" | awk -F '\t' '{ print $1 }' | sort >"$temperature_proof_scaffold_actual_ids"
if ! diff -u "$temperature_proof_scaffold_expected_ids" "$temperature_proof_scaffold_actual_ids" >"$bag_mode_smoke_error"; then
    echo "Temperature provider proof scaffold wrote an unexpected manifest row set" >&2
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
for check_id in "${temperature_proof_required_checks[@]}"; do
    if ! awk -F '\t' -v check_id="$check_id" '$1 == check_id && $2 == "TODO" { found = 1 } END { exit !found }' "$temperature_proof_scaffold/provider-manifest.tsv"; then
        echo "Temperature provider proof scaffold missing required TODO row: $check_id" >&2
        cat "$temperature_proof_scaffold/provider-manifest.tsv" >&2
        exit 1
    fi
done
if ! awk -F '\t' '$1 == "combined-sensor-signal" && $2 == "n/a" { combined = 1 } $1 == "provider-update-or-restart" && $2 == "n/a" { restart = 1 } END { exit !(combined && restart) }' "$temperature_proof_scaffold/provider-manifest.tsv"; then
    echo "Temperature provider proof scaffold missing optional n/a rows" >&2
    cat "$temperature_proof_scaffold/provider-manifest.tsv" >&2
    exit 1
fi
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_scaffold/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted the TODO scaffold manifest" >&2
    exit 1
fi
if ! grep -q "missing file: .*validation-config.txt" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_proof_scaffold_file="$bag_mode_smoke_dir/temperature-proof-scaffold-file"
touch "$temperature_proof_scaffold_file"
if scripts/temperature-provider-proof-scaffold.sh --output-dir "$temperature_proof_scaffold_file" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof scaffold accepted an output path that is not a directory" >&2
    exit 1
fi
if ! grep -q "not a directory" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_proof_scaffold_non_empty="$bag_mode_smoke_dir/temperature-proof-scaffold-non-empty"
mkdir -p "$temperature_proof_scaffold_non_empty"
touch "$temperature_proof_scaffold_non_empty/existing"
if scripts/temperature-provider-proof-scaffold.sh --output-dir "$temperature_proof_scaffold_non_empty" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof scaffold overwrote a non-empty output directory" >&2
    exit 1
fi
if ! grep -q "Output directory is not empty" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if zsh scripts/temperature-provider-proof-scaffold.sh --output-dir "$bag_mode_smoke_dir/temperature-proof-scaffold-zsh" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof scaffold unexpectedly ran under explicit zsh" >&2
    exit 1
fi
if ! grep -q "requires bash" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if zsh scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_manifest" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier unexpectedly ran under explicit zsh" >&2
    exit 1
fi
if ! grep -q "requires bash" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_proof_placeholder_dir="$bag_mode_smoke_dir/temperature-proof-placeholder"
cp -R "$temperature_proof_dir" "$temperature_proof_placeholder_dir"
sed -i '' 's/- Result: inconclusive/- Result: pass | fail | inconclusive/' "$temperature_proof_placeholder_dir/manual-result.md"
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_placeholder_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted placeholder manual result" >&2
    exit 1
fi
if ! grep -q "Result" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_proof_missing_dir="$bag_mode_smoke_dir/temperature-proof-missing-row"
cp -R "$temperature_proof_dir" "$temperature_proof_missing_dir"
grep -v '^logs	' "$temperature_proof_missing_dir/provider-manifest.tsv" >"$temperature_proof_missing_dir/provider-manifest.tmp"
mv "$temperature_proof_missing_dir/provider-manifest.tmp" "$temperature_proof_missing_dir/provider-manifest.tsv"
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_missing_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted a missing required row" >&2
    exit 1
fi
if ! grep -q "logs" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_proof_stale_dir="$bag_mode_smoke_dir/temperature-proof-stale"
cp -R "$temperature_proof_dir" "$temperature_proof_stale_dir"
sed -i '' 's/- Freshest reading age seconds: 4/- Freshest reading age seconds: 11/' "$temperature_proof_stale_dir/manual-result.md"
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_stale_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted stale readings beyond freshnessMaxAgeSeconds" >&2
    exit 1
fi
if ! grep -q "Freshest reading age" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_proof_processinfo_dir="$bag_mode_smoke_dir/temperature-proof-processinfo-sole"
cp -R "$temperature_proof_dir" "$temperature_proof_processinfo_dir"
sed -i '' 's/processInfoSupplementalOnly=true/processInfoSupplementalOnly=false/' "$temperature_proof_processinfo_dir/validation-config.txt"
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_processinfo_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted ProcessInfo as non-supplemental cutoff source" >&2
    exit 1
fi
if ! grep -q "processInfoSupplementalOnly" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_proof_prompt_dir="$bag_mode_smoke_dir/temperature-proof-user-prompt"
cp -R "$temperature_proof_dir" "$temperature_proof_prompt_dir"
sed -i '' 's/noUserVisiblePrompts=true/noUserVisiblePrompts=false/' "$temperature_proof_prompt_dir/validation-config.txt"
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_prompt_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted provider path requiring user-visible prompts" >&2
    exit 1
fi
if ! grep -q "noUserVisiblePrompts" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_proof_coverage_dir="$bag_mode_smoke_dir/temperature-proof-insufficient-pass"
cp -R "$temperature_proof_dir" "$temperature_proof_coverage_dir"
sed -i '' 's/closedBagCoverage=requires-combined-signals/closedBagCoverage=insufficient/' "$temperature_proof_coverage_dir/validation-config.txt"
sed -i '' 's/result=inconclusive/result=pass/' "$temperature_proof_coverage_dir/validation-config.txt"
sed -i '' 's/- Closed-bag coverage: requires-combined-signals/- Closed-bag coverage: insufficient/' "$temperature_proof_coverage_dir/manual-result.md"
sed -i '' 's/- Result: inconclusive/- Result: pass/' "$temperature_proof_coverage_dir/manual-result.md"
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_coverage_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted pass with insufficient closed-bag coverage" >&2
    exit 1
fi
if ! grep -q "closedBagCoverage=insufficient" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_proof_intel_pass_dir="$bag_mode_smoke_dir/temperature-proof-intel-pass"
cp -R "$temperature_proof_dir" "$temperature_proof_intel_pass_dir"
sed -i '' 's/cpu=Apple Silicon/cpu=Intel/' "$temperature_proof_intel_pass_dir/validation-config.txt"
sed -i '' 's/result=inconclusive/result=pass/' "$temperature_proof_intel_pass_dir/validation-config.txt"
sed -i '' 's/- Result: inconclusive/- Result: pass/' "$temperature_proof_intel_pass_dir/manual-result.md"
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_intel_pass_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted pass without Apple Silicon evidence" >&2
    exit 1
fi
if ! grep -q "Apple Silicon" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_proof_desktop_pass_dir="$bag_mode_smoke_dir/temperature-proof-desktop-pass"
cp -R "$temperature_proof_dir" "$temperature_proof_desktop_pass_dir"
sed -i '' 's/hardwareClass=MacBook/hardwareClass=desktop/' "$temperature_proof_desktop_pass_dir/validation-config.txt"
sed -i '' 's/result=inconclusive/result=pass/' "$temperature_proof_desktop_pass_dir/validation-config.txt"
sed -i '' 's/- Result: inconclusive/- Result: pass/' "$temperature_proof_desktop_pass_dir/manual-result.md"
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_desktop_pass_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted pass without MacBook evidence" >&2
    exit 1
fi
if ! grep -q "MacBook" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_proof_combined_missing_dir="$bag_mode_smoke_dir/temperature-proof-combined-missing"
cp -R "$temperature_proof_dir" "$temperature_proof_combined_missing_dir"
grep -v '^combined-sensor-signal	' "$temperature_proof_combined_missing_dir/provider-manifest.tsv" >"$temperature_proof_combined_missing_dir/provider-manifest.tmp"
mv "$temperature_proof_combined_missing_dir/provider-manifest.tmp" "$temperature_proof_combined_missing_dir/provider-manifest.tsv"
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_combined_missing_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted missing combined-sensor evidence" >&2
    exit 1
fi
if ! grep -q "combined-sensor-signal" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_proof_combined_na_dir="$bag_mode_smoke_dir/temperature-proof-combined-na"
cp -R "$temperature_proof_dir" "$temperature_proof_combined_na_dir"
sed -i '' 's#combined-sensor-signal	evidence	evidence/combined-sensor-signal.txt	combined signal evidence attached#combined-sensor-signal	n/a		Combined signal evidence omitted in this negative smoke#' "$temperature_proof_combined_na_dir/provider-manifest.tsv"
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_combined_na_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted N/A combined-sensor evidence" >&2
    exit 1
fi
if ! grep -q "combined-sensor-signal" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_proof_placeholder_evidence_dir="$bag_mode_smoke_dir/temperature-proof-placeholder-evidence"
cp -R "$temperature_proof_dir" "$temperature_proof_placeholder_evidence_dir"
echo 'TODO paste output here' >"$temperature_proof_placeholder_evidence_dir/evidence/numeric-temperature-output.txt"
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_placeholder_evidence_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted placeholder evidence content" >&2
    exit 1
fi
if ! grep -q "placeholder" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_proof_symlink_dir="$bag_mode_smoke_dir/temperature-proof-symlink-evidence"
cp -R "$temperature_proof_dir" "$temperature_proof_symlink_dir"
rm "$temperature_proof_symlink_dir/evidence/numeric-temperature-output.txt"
ln -s /etc/hosts "$temperature_proof_symlink_dir/evidence/numeric-temperature-output.txt"
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_symlink_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted symlink evidence outside the package" >&2
    exit 1
fi
if ! grep -q "symlink" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

echo "==> helper service readiness harness smoke"
helper_readiness_dir="$bag_mode_smoke_dir/helper-readiness"
scripts/helper-service-readiness.sh --output-dir "$helper_readiness_dir" >/dev/null
for required_file in \
    codesigning-identities.txt \
    codesigning-identities.status \
    installer-identities.txt \
    installer-identities.status \
    xcodebuild-version.txt \
    xcodebuild-version.status \
    xcodebuild-discovered-version.txt \
    xcodebuild-discovered-version.status \
    swift-version.txt \
    swift-version.status \
    pkgbuild-path.txt \
    pkgbuild-path.status \
    productbuild-path.txt \
    productbuild-path.status \
    xcode-select-path.txt \
    xcode-select-path.status \
    macos-sdk-path.txt \
    macos-sdk-path.status \
    codesign-path.txt \
    codesign-path.status \
    notarytool-path.txt \
    notarytool-path.status \
    validation-config.txt \
    summary.md
do
    if [[ ! -f "$helper_readiness_dir/$required_file" ]]; then
        echo "Helper readiness harness did not write expected file: $required_file" >&2
        exit 1
    fi
done
if ! grep -q '^metadataRedacted=true$' "$helper_readiness_dir/validation-config.txt"; then
    echo "Helper readiness harness did not record redacted metadata mode" >&2
    exit 1
fi
if ! grep -Eq '^xcodeDeveloperDirSource=(environment|xcode-select|applications|none)$' "$helper_readiness_dir/validation-config.txt"; then
    echo "Helper readiness harness did not record a valid Xcode developer directory source" >&2
    exit 1
fi
if grep -Eq '[A-Fa-f0-9]{40}|Developer ID|Apple Development|Apple Distribution|Team ID|[()]' "$helper_readiness_dir/codesigning-identities.txt"; then
    echo "Helper readiness harness wrote raw signing identity details" >&2
    cat "$helper_readiness_dir/codesigning-identities.txt" >&2
    exit 1
fi
if grep -Eq '[A-Fa-f0-9]{40}|Developer ID|Apple Development|Apple Distribution|Team ID|[()]' "$helper_readiness_dir/installer-identities.txt"; then
    echo "Helper readiness harness wrote raw installer identity details" >&2
    cat "$helper_readiness_dir/installer-identities.txt" >&2
    exit 1
fi

helper_file_output="$bag_mode_smoke_dir/helper-output-file"
touch "$helper_file_output"
if scripts/helper-service-readiness.sh --output-dir "$helper_file_output" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper readiness harness accepted an output path that is not a directory" >&2
    exit 1
fi
if ! grep -q 'not a directory' "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_non_empty_dir="$bag_mode_smoke_dir/helper-non-empty"
mkdir -p "$helper_non_empty_dir"
touch "$helper_non_empty_dir/existing"
if scripts/helper-service-readiness.sh --output-dir "$helper_non_empty_dir" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper readiness harness overwrote a non-empty evidence directory" >&2
    exit 1
fi
if ! grep -q 'Output directory is not empty' "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_bad_env_dir="$bag_mode_smoke_dir/helper-bad-env"
if CLAWSHELL_HELPER_READINESS_TIMEOUT_SECONDS=abc \
    scripts/helper-service-readiness.sh --output-dir "$helper_bad_env_dir" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper readiness harness accepted an invalid timeout value" >&2
    exit 1
fi
if [[ -e "$helper_bad_env_dir" ]]; then
    echo "Helper readiness harness created evidence for an invalid timeout value" >&2
    exit 1
fi

helper_fake_xcode_bin="$bag_mode_smoke_dir/helper-fake-xcode-bin"
helper_fake_xcode_app="$bag_mode_smoke_dir/FakeXcode.app"
helper_fake_xcode_developer="$helper_fake_xcode_app/Contents/Developer"
mkdir -p "$helper_fake_xcode_bin" "$helper_fake_xcode_developer/usr/bin"
cat >"$helper_fake_xcode_bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
echo "xcode-select: error: active developer directory is a command line tools instance" >&2
exit 1
EOF
cat >"$helper_fake_xcode_bin/xcode-select" <<'EOF'
#!/usr/bin/env bash
echo "/Library/Developer/CommandLineTools"
EOF
cat >"$helper_fake_xcode_developer/usr/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
echo "Xcode 99.0"
echo "Build version 99A1"
EOF
chmod +x "$helper_fake_xcode_bin/xcodebuild" "$helper_fake_xcode_bin/xcode-select" \
    "$helper_fake_xcode_developer/usr/bin/xcodebuild"
helper_fake_xcode_dir="$bag_mode_smoke_dir/helper-fake-xcode-discovery"
DEVELOPER_DIR="$helper_fake_xcode_app" \
PATH="$helper_fake_xcode_bin:$PATH" \
    scripts/helper-service-readiness.sh --output-dir "$helper_fake_xcode_dir" >/dev/null
if ! grep -q '^xcodeDeveloperDirSource=environment$' "$helper_fake_xcode_dir/validation-config.txt"; then
    echo "Helper readiness harness did not use DEVELOPER_DIR for full Xcode discovery" >&2
    exit 1
fi
if ! grep -q '^xcodebuildActiveAvailable=false$' "$helper_fake_xcode_dir/validation-config.txt"; then
    echo "Helper readiness harness did not distinguish inactive xcodebuild selection" >&2
    exit 1
fi
if ! grep -q '^xcodebuildDiscoveredAvailable=true$' "$helper_fake_xcode_dir/validation-config.txt"; then
    echo "Helper readiness harness did not detect discovered full Xcode" >&2
    exit 1
fi
if ! grep -q '^xcodebuildAvailable=true$' "$helper_fake_xcode_dir/validation-config.txt"; then
    echo "Helper readiness harness did not aggregate discovered Xcode availability" >&2
    exit 1
fi

helper_fake_bin="$bag_mode_smoke_dir/helper-fakes"
mkdir -p "$helper_fake_bin"
cat >"$helper_fake_bin/security" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-p codesigning"* ]]; then
    cat <<EOT
  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Example Person (TEAMID1234)"
     1 valid identities found
EOT
else
    echo "     0 valid identities found"
fi
EOF
cat >"$helper_fake_bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
echo "Xcode 99.0"
EOF
cat >"$helper_fake_bin/swift" <<'EOF'
#!/usr/bin/env bash
echo "Swift fake"
EOF
cat >"$helper_fake_bin/pkgbuild" <<'EOF'
#!/usr/bin/env bash
echo "$0"
EOF
cat >"$helper_fake_bin/productbuild" <<'EOF'
#!/usr/bin/env bash
echo "$0"
EOF
cat >"$helper_fake_bin/xcode-select" <<'EOF'
#!/usr/bin/env bash
echo "/Applications/Xcode.app/Contents/Developer"
EOF
cat >"$helper_fake_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "--sdk macosx --show-sdk-path") echo "/Applications/Xcode.app/SDKs/MacOSX.sdk" ;;
    "--find codesign") echo "/usr/bin/codesign" ;;
    "--find notarytool") echo "/usr/bin/notarytool" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$helper_fake_bin/security" "$helper_fake_bin/xcodebuild" "$helper_fake_bin/swift" \
    "$helper_fake_bin/pkgbuild" "$helper_fake_bin/productbuild" "$helper_fake_bin/xcode-select" "$helper_fake_bin/xcrun"

helper_fake_dev_dir="$bag_mode_smoke_dir/helper-fake-development"
PATH="$helper_fake_bin:$PATH" scripts/helper-service-readiness.sh --output-dir "$helper_fake_dev_dir" >/dev/null
if ! grep -q '^appleDevelopmentIdentityCount=1$' "$helper_fake_dev_dir/validation-config.txt"; then
    echo "Helper readiness harness did not count fake Apple Development identity" >&2
    exit 1
fi
if ! grep -q '^developerIDApplicationIdentityCount=0$' "$helper_fake_dev_dir/validation-config.txt"; then
    echo "Helper readiness harness misclassified fake Apple Development as Developer ID Application" >&2
    exit 1
fi
if ! grep -q '^signedPrototypeReady=false$' "$helper_fake_dev_dir/validation-config.txt"; then
    echo "Helper readiness harness accepted Apple Development identity for distribution readiness" >&2
    exit 1
fi
if grep -Eq '[A-Fa-f0-9]{40}|Example Person|TEAMID1234|Apple Development|[()]' "$helper_fake_dev_dir/codesigning-identities.txt"; then
    echo "Helper readiness harness leaked fake raw signing identity details" >&2
    cat "$helper_fake_dev_dir/codesigning-identities.txt" >&2
    exit 1
fi
if grep -Eq '[A-Fa-f0-9]{40}|Example Person|TEAMID1234|Apple Development|[()]' "$helper_fake_dev_dir/installer-identities.txt"; then
    echo "Helper readiness harness leaked fake raw installer identity details" >&2
    cat "$helper_fake_dev_dir/installer-identities.txt" >&2
    exit 1
fi

cat >"$helper_fake_bin/security" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-p codesigning"* ]]; then
    cat <<EOT
  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Example Corp (TEAMID1234)"
     1 valid identities found
EOT
else
    cat <<EOT
  1) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Developer ID Installer: Example Corp (TEAMID1234)"
     1 valid identities found
EOT
fi
EOF

helper_fake_dist_dir="$bag_mode_smoke_dir/helper-fake-distribution"
PATH="$helper_fake_bin:$PATH" scripts/helper-service-readiness.sh --output-dir "$helper_fake_dist_dir" >/dev/null
if ! grep -q '^developerIDApplicationIdentityCount=1$' "$helper_fake_dist_dir/validation-config.txt"; then
    echo "Helper readiness harness did not count fake Developer ID Application identity" >&2
    exit 1
fi
if ! grep -q '^developerIDInstallerIdentityCount=1$' "$helper_fake_dist_dir/validation-config.txt"; then
    echo "Helper readiness harness did not count fake Developer ID Installer identity" >&2
    exit 1
fi
if ! grep -q '^signedPrototypeReady=true$' "$helper_fake_dist_dir/validation-config.txt"; then
    echo "Helper readiness harness did not accept fake distribution prerequisites" >&2
    exit 1
fi

helper_timeout_bin="$bag_mode_smoke_dir/helper-timeout-fake"
mkdir -p "$helper_timeout_bin"
cat >"$helper_timeout_bin/security" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
chmod +x "$helper_timeout_bin/security"
helper_timeout_dir="$bag_mode_smoke_dir/helper-timeout"
CLAWSHELL_HELPER_READINESS_TIMEOUT_SECONDS=1 \
PATH="$helper_timeout_bin:$PATH" scripts/helper-service-readiness.sh --output-dir "$helper_timeout_dir" >/dev/null
if ! grep -q '^timedOut=true$' "$helper_timeout_dir/codesigning-identities.status"; then
    echo "Helper readiness harness did not record timeout for hanging security command" >&2
    cat "$helper_timeout_dir/codesigning-identities.status" >&2
    exit 1
fi

echo "==> helper service prototype verifier smoke"
helper_prototype_dir="$bag_mode_smoke_dir/helper-prototype"
helper_prototype_manifest="$helper_prototype_dir/prototype-manifest.tsv"
helper_prototype_evidence_dir="$helper_prototype_dir/evidence"
mkdir -p "$helper_prototype_evidence_dir"
cat >"$helper_prototype_dir/validation-config.txt" <<'EOF'
evidenceFormat=smappservice-prototype-v1
metadataRedacted=true
macOSVersion=15.0
appBundleIdentifier=com.example.ClawShell
helperLabel=com.example.ClawShell.Helper
launchDaemonPlist=ClawShell.app/Contents/Library/LaunchDaemons/com.example.ClawShell.Helper.plist
developerIDApplicationSigned=true
packageInstallerUsed=false
homebrewCaskUsed=false
result=pass
EOF
cat >"$helper_prototype_dir/manual-result.md" <<'EOF'
# Helper Service Prototype Result

## Prototype Case
- Case ID: validate-helper-smoke
- macOS: 15.0
- App bundle: /Applications/ClawShell.app
- LaunchDaemon plist: ClawShell.app/Contents/Library/LaunchDaemons/com.example.ClawShell.Helper.plist
- SMAppService API: SMAppService.daemon(plistName:)

## Signing
- App signed: yes
- Helper signed: yes
- Designated requirements recorded: yes
- Package installer used: no
- Package signed with Developer ID Installer: N/A - no package installer used

## Lifecycle
- Register status transition: requiresApproval -> enabled
- System Settings approval confirmed: yes
- Helper bootstraps after approval: yes
- Helper bootstraps after reboot: yes
- Old helper inactive after update: yes
- Ledger compatibility or repair checked: yes
- Uninstall unloaded helper: yes
- Helper-owned Bag Mode state removed: yes

## Failure Cases
- Failure cases recorded: yes
- Homebrew cask used: no
- Homebrew cask registers helper during install: N/A - cask not used

## Conclusion
- Result: pass
EOF
helper_prototype_required_checks=(
    app-bundle-layout
    launchdaemon-plist
    app-codesign
    helper-codesign
    app-designated-requirement
    helper-designated-requirement
    spctl-assessment
    smappservice-register
    smappservice-status-requires-approval
    system-settings-approval
    smappservice-status-enabled
    helper-bootstrap-after-approval
    post-reboot-helper-bootstrap
    helper-update-old-inactive
    helper-update-ledger-compatibility
    helper-uninstall-unregister
    helper-uninstall-state-cleanup
    failure-unsigned-caller
    failure-wrong-bundle-id-or-label
    failure-wrong-user
    failure-stale-app-version
    failure-denied-or-revoked-approval
    launchctl-status
    log-evidence
)
{
    printf 'checkId\tstatus\tevidencePath\tnote\n'
    for check_id in "${helper_prototype_required_checks[@]}"; do
        printf '$ %s\ncaptured helper prototype output for %s\n' "$check_id" "$check_id" >"$helper_prototype_evidence_dir/$check_id.txt"
        printf '%s\tevidence\tevidence/%s.txt\tevidence attached\n' "$check_id" "$check_id"
    done
    printf 'package-installer-signing\tn/a\t\tNo package installer used in this smoke\n'
    printf 'homebrew-cask-semantics\tn/a\t\tNo Homebrew cask used in this smoke\n'
} >"$helper_prototype_manifest"
scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_manifest" >/dev/null

helper_prototype_scaffold="$bag_mode_smoke_dir/helper-prototype-scaffold"
scripts/helper-service-prototype-scaffold.sh --output-dir "$helper_prototype_scaffold" >/dev/null
for required_file in prototype-manifest.tsv README.md scaffold-config.txt; do
    if [[ ! -f "$helper_prototype_scaffold/$required_file" ]]; then
        echo "Helper service prototype scaffold did not write expected file: $required_file" >&2
        exit 1
    fi
done
if [[ -f "$helper_prototype_scaffold/validation-config.txt" || -f "$helper_prototype_scaffold/manual-result.md" ]]; then
    echo "Helper service prototype scaffold wrote evidence-shaped files before real capture" >&2
    exit 1
fi
if ! grep -q '^scaffoldFormat=smappservice-prototype-scaffold-v1$' "$helper_prototype_scaffold/scaffold-config.txt"; then
    echo "Helper service prototype scaffold did not record expected scaffold format" >&2
    exit 1
fi
for check_id in "${helper_prototype_required_checks[@]}"; do
    if ! awk -F '\t' -v check_id="$check_id" '$1 == check_id && $2 == "TODO" { found = 1 } END { exit !found }' "$helper_prototype_scaffold/prototype-manifest.tsv"; then
        echo "Helper service prototype scaffold missing required TODO row: $check_id" >&2
        cat "$helper_prototype_scaffold/prototype-manifest.tsv" >&2
        exit 1
    fi
done
if ! awk -F '\t' '$1 == "package-installer-signing" && $2 == "n/a" { package = 1 } $1 == "homebrew-cask-semantics" && $2 == "n/a" { cask = 1 } END { exit !(package && cask) }' "$helper_prototype_scaffold/prototype-manifest.tsv"; then
    echo "Helper service prototype scaffold missing optional n/a rows" >&2
    cat "$helper_prototype_scaffold/prototype-manifest.tsv" >&2
    exit 1
fi
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_scaffold/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted the TODO scaffold manifest" >&2
    exit 1
fi
if ! grep -q "missing file: .*validation-config.txt" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_prototype_scaffold_file="$bag_mode_smoke_dir/helper-prototype-scaffold-file"
touch "$helper_prototype_scaffold_file"
if scripts/helper-service-prototype-scaffold.sh --output-dir "$helper_prototype_scaffold_file" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype scaffold accepted an output path that is not a directory" >&2
    exit 1
fi
if ! grep -q "not a directory" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_prototype_scaffold_non_empty="$bag_mode_smoke_dir/helper-prototype-scaffold-non-empty"
mkdir -p "$helper_prototype_scaffold_non_empty"
touch "$helper_prototype_scaffold_non_empty/existing"
if scripts/helper-service-prototype-scaffold.sh --output-dir "$helper_prototype_scaffold_non_empty" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype scaffold overwrote a non-empty output directory" >&2
    exit 1
fi
if ! grep -q "Output directory is not empty" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if zsh scripts/helper-service-prototype-scaffold.sh --output-dir "$bag_mode_smoke_dir/helper-prototype-scaffold-zsh" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype scaffold unexpectedly ran under explicit zsh" >&2
    exit 1
fi
if ! grep -q "requires bash" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if zsh scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_manifest" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier unexpectedly ran under explicit zsh" >&2
    exit 1
fi
if ! grep -q "requires bash" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_prototype_placeholder_dir="$bag_mode_smoke_dir/helper-prototype-placeholder"
cp -R "$helper_prototype_dir" "$helper_prototype_placeholder_dir"
sed -i '' 's/- Result: pass/- Result: pass | fail | inconclusive/' "$helper_prototype_placeholder_dir/manual-result.md"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_placeholder_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted placeholder manual result" >&2
    exit 1
fi
if ! grep -q "Result" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_prototype_missing_dir="$bag_mode_smoke_dir/helper-prototype-missing-row"
cp -R "$helper_prototype_dir" "$helper_prototype_missing_dir"
grep -v '^log-evidence	' "$helper_prototype_missing_dir/prototype-manifest.tsv" >"$helper_prototype_missing_dir/prototype-manifest.tmp"
mv "$helper_prototype_missing_dir/prototype-manifest.tmp" "$helper_prototype_missing_dir/prototype-manifest.tsv"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_missing_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted a missing required row" >&2
    exit 1
fi
if ! grep -q "log-evidence" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_prototype_empty_dir="$bag_mode_smoke_dir/helper-prototype-empty-evidence"
cp -R "$helper_prototype_dir" "$helper_prototype_empty_dir"
: >"$helper_prototype_empty_dir/evidence/app-codesign.txt"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_empty_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted empty evidence" >&2
    exit 1
fi
if ! grep -q "empty" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_prototype_placeholder_evidence_dir="$bag_mode_smoke_dir/helper-prototype-placeholder-evidence"
cp -R "$helper_prototype_dir" "$helper_prototype_placeholder_evidence_dir"
echo 'TODO paste output here' >"$helper_prototype_placeholder_evidence_dir/evidence/app-codesign.txt"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_placeholder_evidence_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted placeholder evidence content" >&2
    exit 1
fi
if ! grep -q "placeholder" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_prototype_symlink_dir="$bag_mode_smoke_dir/helper-prototype-symlink-evidence"
cp -R "$helper_prototype_dir" "$helper_prototype_symlink_dir"
rm "$helper_prototype_symlink_dir/evidence/app-codesign.txt"
ln -s /etc/hosts "$helper_prototype_symlink_dir/evidence/app-codesign.txt"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_symlink_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted symlink evidence outside the package" >&2
    exit 1
fi
if ! grep -q "symlink" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_prototype_dir_symlink_dir="$bag_mode_smoke_dir/helper-prototype-directory-symlink-evidence"
cp -R "$helper_prototype_dir" "$helper_prototype_dir_symlink_dir"
mkdir "$helper_prototype_dir_symlink_dir/evidence/app-codesign-dir"
printf '$ app-codesign\ncaptured app codesign output\n' >"$helper_prototype_dir_symlink_dir/evidence/app-codesign-dir/output.txt"
ln -s /etc/hosts "$helper_prototype_dir_symlink_dir/evidence/app-codesign-dir/escaped-hosts"
sed -i '' 's#app-codesign	evidence	evidence/app-codesign.txt#app-codesign	evidence	evidence/app-codesign-dir#' "$helper_prototype_dir_symlink_dir/prototype-manifest.tsv"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_dir_symlink_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted symlink evidence inside a directory" >&2
    exit 1
fi
if ! grep -q "symlink" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_prototype_mismatch_dir="$bag_mode_smoke_dir/helper-prototype-config-manual-mismatch"
cp -R "$helper_prototype_dir" "$helper_prototype_mismatch_dir"
sed -i '' 's/- Result: pass/- Result: fail/' "$helper_prototype_mismatch_dir/manual-result.md"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_mismatch_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted mismatched config/manual result" >&2
    exit 1
fi
if ! grep -q "Result field must match" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_prototype_plist_mismatch_dir="$bag_mode_smoke_dir/helper-prototype-plist-mismatch"
cp -R "$helper_prototype_dir" "$helper_prototype_plist_mismatch_dir"
sed -i '' 's#ClawShell.app/Contents/Library/LaunchDaemons/com.example.ClawShell.Helper.plist#ClawShell.app/Contents/Library/LaunchDaemons/com.example.ClawShell.Helper.plist.bak#' "$helper_prototype_plist_mismatch_dir/manual-result.md"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_plist_mismatch_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted mismatched LaunchDaemon plist" >&2
    exit 1
fi
if ! grep -q "LaunchDaemon plist" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_prototype_package_dir="$bag_mode_smoke_dir/helper-prototype-package-missing"
cp -R "$helper_prototype_dir" "$helper_prototype_package_dir"
sed -i '' 's/packageInstallerUsed=false/packageInstallerUsed=true/' "$helper_prototype_package_dir/validation-config.txt"
sed -i '' 's/- Package installer used: no/- Package installer used: yes/' "$helper_prototype_package_dir/manual-result.md"
sed -i '' 's/- Package signed with Developer ID Installer: N\/A - no package installer used/- Package signed with Developer ID Installer: yes/' "$helper_prototype_package_dir/manual-result.md"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_package_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted package usage with N/A package signing evidence" >&2
    exit 1
fi
if ! grep -q "package-installer-signing" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_prototype_cask_na_dir="$bag_mode_smoke_dir/helper-prototype-cask-na"
cp -R "$helper_prototype_dir" "$helper_prototype_cask_na_dir"
sed -i '' 's/homebrewCaskUsed=false/homebrewCaskUsed=true/' "$helper_prototype_cask_na_dir/validation-config.txt"
sed -i '' 's/- Homebrew cask used: no/- Homebrew cask used: yes/' "$helper_prototype_cask_na_dir/manual-result.md"
sed -i '' 's/- Homebrew cask registers helper during install: N\/A - cask not used/- Homebrew cask registers helper during install: no/' "$helper_prototype_cask_na_dir/manual-result.md"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_cask_na_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted cask usage with N/A cask evidence" >&2
    exit 1
fi
if ! grep -q "homebrew-cask-semantics" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_prototype_cask_dir="$bag_mode_smoke_dir/helper-prototype-cask-register"
cp -R "$helper_prototype_dir" "$helper_prototype_cask_dir"
sed -i '' 's/homebrewCaskUsed=false/homebrewCaskUsed=true/' "$helper_prototype_cask_dir/validation-config.txt"
sed -i '' 's/- Homebrew cask used: no/- Homebrew cask used: yes/' "$helper_prototype_cask_dir/manual-result.md"
sed -i '' 's/- Homebrew cask registers helper during install: N\/A - cask not used/- Homebrew cask registers helper during install: yes/' "$helper_prototype_cask_dir/manual-result.md"
printf 'cask evidence\n' >"$helper_prototype_cask_dir/evidence/homebrew-cask-semantics.txt"
sed -i '' 's/^homebrew-cask-semantics	n\/a		No Homebrew cask used in this smoke/homebrew-cask-semantics	evidence	evidence\/homebrew-cask-semantics.txt	cask evidence attached/' "$helper_prototype_cask_dir/prototype-manifest.tsv"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_cask_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted cask install registering the helper" >&2
    exit 1
fi
if ! grep -q "Homebrew cask install" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

echo "==> swift test discovery"
test_list_output="$(mktemp)"
test_list_error="$(mktemp)"
test_developer_dir=""
test_discovered_with_xcode=false

if swift_test_list_with_developer_dir "" "$test_list_output" "$test_list_error"; then
    :
else
    if swift_test_unavailable_only "$test_list_error"; then
        discovered_developer_dir="$(discover_swift_test_developer_dir || true)"
        if [[ -n "$discovered_developer_dir" ]]; then
            echo "==> swift test discovery with discovered Xcode: $discovered_developer_dir"
            : >"$test_list_output"
            : >"$test_list_error"
            if swift_test_list_with_developer_dir "$discovered_developer_dir" "$test_list_output" "$test_list_error"; then
                test_developer_dir="$discovered_developer_dir"
                test_discovered_with_xcode=true
            elif swift_test_unavailable_only "$test_list_error"; then
                echo "==> swift test skipped: discovered Xcode still does not provide Testing or XCTest"
                exit 0
            else
                cat "$test_list_error" >&2
                exit 1
            fi
        else
            echo "==> swift test skipped: this toolchain does not provide Testing or XCTest"
            exit 0
        fi
    else
        cat "$test_list_error" >&2
        exit 1
    fi
fi

if [[ -s "$test_list_output" ]]; then
    missing_targets=()
    for target in ClawShellCoreTests ClawShellContractTests; do
        if ! grep -q "$target" "$test_list_output"; then
            missing_targets+=("$target")
        fi
    done

    if [[ "${#missing_targets[@]}" -gt 0 ]]; then
        echo "swift test list succeeded but missed required test target(s): ${missing_targets[*]}" >&2
        cat "$test_list_output" >&2
        exit 1
    fi

    echo "==> swift test"
    if [[ "$test_discovered_with_xcode" == true ]]; then
        echo "==> using discovered Xcode for swift test: $test_developer_dir"
    fi
    swift_test_with_developer_dir "$test_developer_dir"
else
    if [[ "$test_discovered_with_xcode" == true ]]; then
        echo "swift test list with discovered Xcode produced no output" >&2
    else
        echo "swift test list produced no output" >&2
    fi
    exit 1
fi
