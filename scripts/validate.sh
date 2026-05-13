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

echo "==> temperature numeric detector smoke"
temperature_numeric_grep_pattern='(-?[0-9]+([.][0-9]+)?([[:blank:]]*°C|[[:blank:]]+(celsius|degrees?[[:blank:]]*C|C\>)))|((^|[^A-Za-z0-9_-])([A-Za-z0-9]*temperature|temp)[^A-Za-z0-9_:=.-]*(=|:)[[:blank:]]*-?[0-9]+([.][0-9]+)?([[:blank:]]*(°C|celsius|degrees?[[:blank:]]*C|C\>))?)'
swift - <<'SWIFT'
import Foundation

let numericTemperaturePatterns = [
    #"-?\d+(\.\d+)?([ \t]*°C|[ \t]+(celsius|degrees?[ \t]*C|C\b))"#,
    #"(^|[^A-Za-z0-9_-])([A-Za-z0-9]*temperature|temp)[^A-Za-z0-9_:=.-]*(=|:)[ \t]*-?\d+(\.\d+)?([ \t]*(°C|celsius|degrees?[ \t]*C|C\b))?"#,
]

func detectsTemperature(_ text: String) -> Bool {
    numericTemperaturePatterns.contains { pattern in
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

let positiveFixtures = [
    "CPU die temperature: 42 C",
    "Battery Temperature = 31.5 Celsius",
    "\"VirtualTemperature\" = 3279",
    "SoC sensor 47°C",
    "temperature: 42",
]
let negativeFixtures = [
    "0.00               \nCodex Helper",
    "Name ID CPU ms/s User%",
    "thermalmonitord 550 0.15 47.90",
    "Current pressure level: Nominal",
    "attempt 3",
    "template 42",
    "temporary reading 31",
    "\"Temperature\" = <02007c>",
]

for fixture in positiveFixtures where !detectsTemperature(fixture) {
    fatalError("Temperature detector missed positive fixture: \(fixture)")
}
for fixture in negativeFixtures where detectsTemperature(fixture) {
    fatalError("Temperature detector accepted negative fixture: \(fixture)")
}
SWIFT
swift - <<'SWIFT'
import Foundation

let numericTemperaturePatterns = [
    #"-?\d+(\.\d+)?([ \t]*°C|[ \t]+(celsius|degrees?[ \t]*C|C\b))"#,
    #"(^|[^A-Za-z0-9_-])([A-Za-z0-9]*temperature|temp)[^A-Za-z0-9_:=.-]*(=|:)[ \t]*-?\d+(\.\d+)?([ \t]*(°C|celsius|degrees?[ \t]*C|C\b))?"#,
]

func matchesNumericTemperature(_ text: String) -> Bool {
    numericTemperaturePatterns.contains { pattern in
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

func groups(for regex: NSRegularExpression, in text: String) -> [String]? {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range) else {
        return nil
    }

    var values: [String] = []
    for index in 1..<match.numberOfRanges {
        guard let groupRange = Range(match.range(at: index), in: text) else {
            return nil
        }
        values.append(String(text[groupRange]))
    }
    return values
}

func ioregSMCNumericTemperatureAnalysis(_ text: String) -> (candidateCount: Int, acceptedCount: Int, rejectedBatteryContextCount: Int) {
    let nodeRegex = try! NSRegularExpression(pattern: #"^([ \t|]*)\+-o[ \t]+([^ \t<]+)"#)
    var stack: [(indent: Int, name: String)] = []
    var candidateCount = 0
    var acceptedCount = 0
    var rejectedBatteryContextCount = 0

    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if let nodeGroups = groups(for: nodeRegex, in: line), nodeGroups.count == 2 {
            let indent = nodeGroups[0].count
            while let last = stack.last, last.indent >= indent {
                stack.removeLast()
            }
            stack.append((indent: indent, name: nodeGroups[1]))
        }

        guard matchesNumericTemperature(line) else {
            continue
        }

        candidateCount += 1
        let inBatteryContext = stack.contains { node in
            node.name == "AppleSmartBattery" || node.name == "AppleSmartBatteryManager"
        }
        if inBatteryContext {
            rejectedBatteryContextCount += 1
        } else {
            acceptedCount += 1
        }
    }

    return (candidateCount, acceptedCount, rejectedBatteryContextCount)
}

let batteryOnly = """
+-o Root
  +-o AppleSmartBatteryManager
    +-o AppleSmartBattery
      "Temperature" = 3044
      "VirtualTemperature" = 3119
"""
let mixed = """
+-o Root
  +-o AppleSmartBattery
    "Temperature" = 3044
  +-o AppleThermalZone
    "Temperature" = 4200
"""
let branchPrefixedBattery = """
+-o Root
| +-o AppleSmartBatteryManager
| | +-o AppleSmartBattery
| |   "Temperature" = 3044
| |   "VirtualTemperature" = 3119
"""

let batteryOnlyAnalysis = ioregSMCNumericTemperatureAnalysis(batteryOnly)
if batteryOnlyAnalysis.candidateCount != 2 ||
    batteryOnlyAnalysis.acceptedCount != 0 ||
    batteryOnlyAnalysis.rejectedBatteryContextCount != 2 {
    fatalError("ioreg-smc battery-only analysis should reject battery-context candidates: \(batteryOnlyAnalysis)")
}

let mixedAnalysis = ioregSMCNumericTemperatureAnalysis(mixed)
if mixedAnalysis.candidateCount != 2 ||
    mixedAnalysis.acceptedCount != 1 ||
    mixedAnalysis.rejectedBatteryContextCount != 1 {
    fatalError("ioreg-smc mixed analysis should accept only non-battery candidates: \(mixedAnalysis)")
}

let branchPrefixedBatteryAnalysis = ioregSMCNumericTemperatureAnalysis(branchPrefixedBattery)
if branchPrefixedBatteryAnalysis.candidateCount != 2 ||
    branchPrefixedBatteryAnalysis.acceptedCount != 0 ||
    branchPrefixedBatteryAnalysis.rejectedBatteryContextCount != 2 {
    fatalError("ioreg-smc branch-prefixed battery analysis should reject battery-context candidates: \(branchPrefixedBatteryAnalysis)")
}
SWIFT
swift - <<'SWIFT'
import Foundation

let raw = Data("abc🙂".utf8).prefix(5)
let text = String(decoding: raw, as: UTF8.self)
precondition(raw.count == 5, "bounded capture must retain raw byte count")
precondition(!text.isEmpty, "bounded capture must decode partial UTF-8 with replacement semantics")
precondition(String(data: raw, encoding: .utf8) == nil, "fixture should prove strict UTF-8 decoding would drop the snapshot")
SWIFT
swift - <<'SWIFT'
import Foundation

func readBoundedData(from url: URL, limit: Int) -> (Data, Bool) {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
        return (Data(), false)
    }
    defer {
        try? handle.close()
    }
    let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
    if data.count > limit {
        return (Data(data.prefix(limit)), true)
    }
    return (data, false)
}

let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clawshell-bounded-output-\(UUID().uuidString)")
try Data(repeating: 65, count: 2_000_005).write(to: url)
defer {
    try? FileManager.default.removeItem(at: url)
}
let output = readBoundedData(from: url, limit: 2_000_000)
precondition(output.0.count == 2_000_000, "bounded capture must not read past byte limit")
precondition(output.1 == true, "bounded capture must flag truncation")
SWIFT
for positive_fixture in \
    'CPU die temperature: 42 C' \
    'Battery Temperature = 31.5 Celsius' \
    '"VirtualTemperature" = 3279' \
    'SoC sensor 47°C' \
    'temperature: 42'
do
    if ! printf '%s\n' "$positive_fixture" | grep -Eiq "$temperature_numeric_grep_pattern"; then
        echo "grep temperature detector missed positive fixture: $positive_fixture" >&2
        exit 1
    fi
done
for negative_fixture in \
    $'0.00               \nCodex Helper' \
    'Name ID CPU ms/s User%' \
    'thermalmonitord 550 0.15 47.90' \
    'Current pressure level: Nominal' \
    'attempt 3' \
    'template 42' \
    'temporary reading 31' \
    '"Temperature" = <02007c>'
do
    if printf '%s\n' "$negative_fixture" | grep -Eiq "$temperature_numeric_grep_pattern"; then
        echo "grep temperature detector accepted negative fixture: $negative_fixture" >&2
        exit 1
    fi
done

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
    if [[ "${CLAWSHELL_FAKE_PMSET_EMPTY_DISABLESLEEP_ON_READ:-0}" == "1" ]]; then
        printf ' disablesleep\n'
    elif [[ "${CLAWSHELL_FAKE_PMSET_OMIT_DISABLESLEEP_ON_READ:-0}" != "1" ]]; then
        printf ' disablesleep %s\n' "$(cat "$state_file")"
    fi
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

bag_mode_apply_missing_transition="$bag_mode_smoke_dir/apply-missing-disablesleep"
bag_mode_apply_missing_state="$bag_mode_smoke_dir/apply-missing-state"
bag_mode_apply_missing_log="$bag_mode_smoke_dir/apply-missing-commands.log"
printf '0\n' >"$bag_mode_apply_missing_state"
touch "$bag_mode_apply_missing_log"
scripts/bag-mode-primitive-validation.sh \
    --output-dir "$bag_mode_apply_missing_transition" \
    --case-id validate-apply-missing-disablesleep >/dev/null
PATH="$bag_mode_apply_bin:$PATH" \
CLAWSHELL_BAG_MODE_PRIMITIVE_TEST_PMSET=1 \
CLAWSHELL_PMSET_BIN="$bag_mode_apply_bin/pmset" \
CLAWSHELL_FAKE_PMSET_STATE="$bag_mode_apply_missing_state" \
CLAWSHELL_FAKE_PMSET_LOG="$bag_mode_apply_missing_log" \
CLAWSHELL_FAKE_PMSET_OMIT_DISABLESLEEP_ON_READ=1 \
    scripts/bag-mode-primitive-validation.sh \
        --output-dir "$bag_mode_apply_missing_transition" \
        --case-id validate-apply-missing-disablesleep \
        --hold-seconds 1 \
        --apply \
        --continue \
        --i-understand-this-changes-power-settings >/dev/null
if ! grep -q '^previousDisablesleep=0$' "$bag_mode_apply_missing_transition/validation-config.txt"; then
    echo "Bag Mode primitive harness did not treat a missing disablesleep row as default/off" >&2
    exit 1
fi
if ! grep -q '^rollbackCommand=.*/pmset disablesleep 0$' "$bag_mode_apply_missing_transition/validation-config.txt"; then
    echo "Bag Mode primitive harness did not record rollback to default/off for a missing disablesleep row" >&2
    exit 1
fi
if [[ "$(cat "$bag_mode_apply_missing_state")" != "0" ]]; then
    echo "Bag Mode primitive harness fake pmset state did not return to default/off for missing disablesleep row" >&2
    exit 1
fi
if ! grep -q '^disablesleep 1$' "$bag_mode_apply_missing_log" ||
   ! grep -q '^disablesleep 0$' "$bag_mode_apply_missing_log"; then
    echo "Bag Mode primitive harness did not apply and roll back when disablesleep row is absent" >&2
    cat "$bag_mode_apply_missing_log" >&2
    exit 1
fi

bag_mode_apply_empty_transition="$bag_mode_smoke_dir/apply-empty-disablesleep"
bag_mode_apply_empty_state="$bag_mode_smoke_dir/apply-empty-state"
bag_mode_apply_empty_log="$bag_mode_smoke_dir/apply-empty-commands.log"
bag_mode_apply_empty_error="$bag_mode_smoke_dir/apply-empty-error.txt"
printf '0\n' >"$bag_mode_apply_empty_state"
touch "$bag_mode_apply_empty_log"
scripts/bag-mode-primitive-validation.sh \
    --output-dir "$bag_mode_apply_empty_transition" \
    --case-id validate-apply-empty-disablesleep >/dev/null
set +e
PATH="$bag_mode_apply_bin:$PATH" \
CLAWSHELL_BAG_MODE_PRIMITIVE_TEST_PMSET=1 \
CLAWSHELL_PMSET_BIN="$bag_mode_apply_bin/pmset" \
CLAWSHELL_FAKE_PMSET_STATE="$bag_mode_apply_empty_state" \
CLAWSHELL_FAKE_PMSET_LOG="$bag_mode_apply_empty_log" \
CLAWSHELL_FAKE_PMSET_EMPTY_DISABLESLEEP_ON_READ=1 \
    scripts/bag-mode-primitive-validation.sh \
        --output-dir "$bag_mode_apply_empty_transition" \
        --case-id validate-apply-empty-disablesleep \
        --hold-seconds 1 \
        --apply \
        --continue \
        --i-understand-this-changes-power-settings >"$bag_mode_apply_empty_error" 2>&1
bag_mode_apply_empty_status=$?
set -e
if [[ "$bag_mode_apply_empty_status" -eq 0 ]]; then
    echo "Bag Mode primitive harness accepted malformed empty disablesleep row" >&2
    exit 1
fi
if grep -q '^disablesleep 1$' "$bag_mode_apply_empty_log"; then
    echo "Bag Mode primitive harness mutated power settings after malformed empty disablesleep row" >&2
    cat "$bag_mode_apply_empty_log" >&2
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
cat >"$bag_mode_smoke_dir/matrix/deferred-placeholder-manifest.tsv" <<'EOF'
caseId	status	evidenceDir	naReason
validate-smoke	evidence	validate-smoke	evidence attached
macos-13-intel-deferred	deferred		TBD
EOF
if scripts/bag-mode-primitive-matrix-verify.sh --manifest "$bag_mode_smoke_dir/matrix/deferred-placeholder-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted placeholder deferred reason" >&2
    exit 1
fi
if ! grep -q "macos-13-intel-deferred" "$bag_mode_smoke_error"; then
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
if [[ "$(head -n 1 "$bag_mode_matrix_scaffold/matrix-manifest.tsv")" != $'caseId\tstatus\tevidenceDir\tnaReason' ]]; then
    echo "Bag Mode primitive matrix scaffold wrote an unexpected manifest header" >&2
    cat "$bag_mode_matrix_scaffold/matrix-manifest.tsv" >&2
    exit 1
fi
if ! awk -F '\t' 'NR == 1 { next } NF != 4 { exit 1 }' "$bag_mode_matrix_scaffold/matrix-manifest.tsv"; then
    echo "Bag Mode primitive matrix scaffold wrote a manifest row with an unexpected field count" >&2
    cat "$bag_mode_matrix_scaffold/matrix-manifest.tsv" >&2
    exit 1
fi
bag_mode_matrix_scaffold_todo_cases=(
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
)
bag_mode_matrix_scaffold_expected_ids="$bag_mode_smoke_dir/matrix-scaffold-expected-ids"
bag_mode_matrix_scaffold_actual_ids="$bag_mode_smoke_dir/matrix-scaffold-actual-ids"
{
    for case_id in "${bag_mode_matrix_scaffold_todo_cases[@]}"; do
        printf '%s\n' "$case_id"
    done
    printf '%s\n' "helper-restart-after-27"
    printf '%s\n' "helper-upgrade-after-27"
} | sort >"$bag_mode_matrix_scaffold_expected_ids"
tail -n +2 "$bag_mode_matrix_scaffold/matrix-manifest.tsv" | awk -F '\t' '{ print $1 }' | sort >"$bag_mode_matrix_scaffold_actual_ids"
if ! diff -u "$bag_mode_matrix_scaffold_expected_ids" "$bag_mode_matrix_scaffold_actual_ids" >"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix scaffold wrote an unexpected manifest row set" >&2
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
for case_id in "${bag_mode_matrix_scaffold_todo_cases[@]}"; do
    if ! awk -F '\t' -v case_id="$case_id" '$1 == case_id && $2 == "TODO" { found = 1 } END { exit !found }' "$bag_mode_matrix_scaffold/matrix-manifest.tsv"; then
        echo "Bag Mode primitive matrix scaffold missing TODO row: $case_id" >&2
        cat "$bag_mode_matrix_scaffold/matrix-manifest.tsv" >&2
        exit 1
    fi
done
if ! awk -F '\t' '
    function trim(value) {
        gsub(/\r/, "", value)
        sub(/^[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
        return value
    }
    function usable_reason(value) {
        value = trim(value)
        return value != "" && value != "TODO" && value != "TBD" && !(value ~ /</ && value ~ />/) && value !~ / \| /
    }
    $1 == "helper-restart-after-27" && $2 == "deferred" && usable_reason($4) { restart = 1 }
    $1 == "helper-upgrade-after-27" && $2 == "deferred" && usable_reason($4) { upgrade = 1 }
    END { exit !(restart && upgrade) }
' "$bag_mode_matrix_scaffold/matrix-manifest.tsv"; then
    echo "Bag Mode primitive matrix scaffold missing helper deferred rows with reasons" >&2
    cat "$bag_mode_matrix_scaffold/matrix-manifest.tsv" >&2
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
if zsh scripts/bag-mode-primitive-matrix-scaffold.sh --output-dir "$bag_mode_smoke_dir/matrix-scaffold-zsh" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix scaffold unexpectedly ran under explicit zsh" >&2
    exit 1
fi
if ! grep -q "requires bash" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
bag_mode_matrix_scaffold_file="$bag_mode_smoke_dir/matrix-scaffold-file"
touch "$bag_mode_matrix_scaffold_file"
if scripts/bag-mode-primitive-matrix-scaffold.sh --output-dir "$bag_mode_matrix_scaffold_file" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix scaffold accepted an output path that is not a directory" >&2
    exit 1
fi
if ! grep -q "not a directory" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
bag_mode_matrix_scaffold_non_empty="$bag_mode_smoke_dir/matrix-scaffold-non-empty"
mkdir -p "$bag_mode_matrix_scaffold_non_empty"
touch "$bag_mode_matrix_scaffold_non_empty/existing"
if scripts/bag-mode-primitive-matrix-scaffold.sh --output-dir "$bag_mode_matrix_scaffold_non_empty" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix scaffold overwrote a non-empty output directory" >&2
    exit 1
fi
if ! grep -q "Output directory is not empty" "$bag_mode_smoke_error"; then
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
bag_mode_matrix_unredacted_metadata="$bag_mode_smoke_dir/matrix-unredacted-metadata"
cp -R "$bag_mode_matrix_case" "$bag_mode_matrix_unredacted_metadata"
cat >"$bag_mode_matrix_unredacted_metadata/before/metadata.txt" <<'EOF'
capturedAtUTC=2026-05-12T00:00:00Z
host=local-hostname
user=local-user
EOF
if scripts/bag-mode-primitive-matrix-verify.sh --case-dir "$bag_mode_matrix_unredacted_metadata" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted unredacted snapshot metadata" >&2
    exit 1
fi
if ! grep -q "redacted host/user" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
bag_mode_matrix_mixed_metadata="$bag_mode_smoke_dir/matrix-mixed-metadata"
cp -R "$bag_mode_matrix_case" "$bag_mode_matrix_mixed_metadata"
cat >"$bag_mode_matrix_mixed_metadata/before/metadata.txt" <<'EOF'
capturedAtUTC=2026-05-12T00:00:00Z
host=local-hostname
host=<redacted>
user=<redacted>
user=local-user
EOF
if scripts/bag-mode-primitive-matrix-verify.sh --case-dir "$bag_mode_matrix_mixed_metadata" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted mixed redacted and unredacted snapshot metadata" >&2
    exit 1
fi
if ! grep -q "redacted host/user" "$bag_mode_smoke_error"; then
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
printf '$ pmset -g custom\nTODO paste output here\n' >"$bag_mode_matrix_case/after-rollback/pmset-custom.txt"
if scripts/bag-mode-primitive-matrix-verify.sh --case-dir "$bag_mode_matrix_case" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Bag Mode primitive matrix verifier accepted placeholder snapshot output" >&2
    exit 1
fi
if ! grep -q "placeholder content" "$bag_mode_smoke_error"; then
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

echo "==> temperature provider alternate source probe smoke"
temperature_alt_source_dir="$bag_mode_smoke_dir/temperature-alt-source"
scripts/temperature-provider-alt-source-probe.sh --output-dir "$temperature_alt_source_dir" >/dev/null
for required_file in \
    validation-config.txt \
    source-probe-manifest.tsv \
    README.md \
    evidence/smc-endpoint-inventory.txt \
    evidence/smc-endpoint-inventory.status \
    evidence/pmu-temperature-sensor-inventory.txt \
    evidence/pmu-temperature-sensor-inventory.status \
    evidence/nvme-temperature-sensor-inventory.txt \
    evidence/nvme-temperature-sensor-inventory.status \
    evidence/die-temperature-controller-inventory.txt \
    evidence/die-temperature-controller-inventory.status \
    evidence/hidutil-service-inventory.txt \
    evidence/hidutil-service-inventory.status \
    evidence/hidutil-temperature-service-ndjson.txt \
    evidence/hidutil-temperature-service-ndjson.status \
    evidence/hidutil-temperature-service-dump.txt \
    evidence/hidutil-temperature-service-dump.status \
    evidence/ioreport-temperature-legend-inventory.txt \
    evidence/ioreport-temperature-legend-inventory.status \
    evidence/numeric-temperature-candidates.txt \
    evidence/numeric-temperature-candidates.status \
    evidence/rejected-temperature-candidates.txt
do
    if [[ ! -f "$temperature_alt_source_dir/$required_file" ]]; then
        echo "Temperature alternate source probe did not write expected file: $required_file" >&2
        exit 1
    fi
done
if ! grep -q '^providerProofReady=false$' "$temperature_alt_source_dir/validation-config.txt"; then
    echo "Temperature alternate source probe overclaimed provider proof readiness" >&2
    cat "$temperature_alt_source_dir/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^evidenceFormat=temperature-alt-source-probe-v3$' "$temperature_alt_source_dir/validation-config.txt"; then
    echo "Temperature alternate source probe did not record v3 evidence format" >&2
    cat "$temperature_alt_source_dir/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^numericCutoffSource=false$' "$temperature_alt_source_dir/validation-config.txt"; then
    echo "Temperature alternate source probe promoted discovery output to cutoff source" >&2
    cat "$temperature_alt_source_dir/validation-config.txt" >&2
    exit 1
fi
if ! awk -F '\t' '$1 == "numeric-cutoff-source" && $2 == "TODO" { found = 1 } END { exit !found }' "$temperature_alt_source_dir/source-probe-manifest.tsv"; then
    echo "Temperature alternate source probe should leave numeric cutoff source as TODO" >&2
    cat "$temperature_alt_source_dir/source-probe-manifest.tsv" >&2
    exit 1
fi
temperature_alt_source_file="$bag_mode_smoke_dir/temperature-alt-source-file"
touch "$temperature_alt_source_file"
if scripts/temperature-provider-alt-source-probe.sh --output-dir "$temperature_alt_source_file" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature alternate source probe accepted an output path that is not a directory" >&2
    exit 1
fi
if ! grep -q 'not a directory' "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_alt_source_non_empty="$bag_mode_smoke_dir/temperature-alt-source-non-empty"
mkdir -p "$temperature_alt_source_non_empty"
touch "$temperature_alt_source_non_empty/existing"
if scripts/temperature-provider-alt-source-probe.sh --output-dir "$temperature_alt_source_non_empty" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature alternate source probe overwrote a non-empty output directory" >&2
    exit 1
fi
if ! grep -q 'Output directory is not empty' "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_alt_source_bad_env="$bag_mode_smoke_dir/temperature-alt-source-bad-env"
if CLAWSHELL_TEMPERATURE_ALT_SOURCE_TIMEOUT_SECONDS=abc \
    scripts/temperature-provider-alt-source-probe.sh --output-dir "$temperature_alt_source_bad_env" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature alternate source probe accepted an invalid timeout value" >&2
    exit 1
fi
if [[ -e "$temperature_alt_source_bad_env" ]]; then
    echo "Temperature alternate source probe created evidence for an invalid timeout value" >&2
    exit 1
fi
temperature_alt_source_bad_lines="$bag_mode_smoke_dir/temperature-alt-source-bad-lines"
if CLAWSHELL_TEMPERATURE_ALT_SOURCE_MAX_LINES=abc \
    scripts/temperature-provider-alt-source-probe.sh --output-dir "$temperature_alt_source_bad_lines" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature alternate source probe accepted an invalid max-lines value" >&2
    exit 1
fi
if [[ -e "$temperature_alt_source_bad_lines" ]]; then
    echo "Temperature alternate source probe created evidence for an invalid max-lines value" >&2
    exit 1
fi
temperature_alt_source_symlink="$bag_mode_smoke_dir/temperature-alt-source-symlink"
temperature_alt_source_symlink_target="$bag_mode_smoke_dir/temperature-alt-source-symlink-target"
mkdir -p "$temperature_alt_source_symlink_target"
ln -s "$temperature_alt_source_symlink_target" "$temperature_alt_source_symlink"
if scripts/temperature-provider-alt-source-probe.sh --output-dir "$temperature_alt_source_symlink" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature alternate source probe accepted a symlinked output directory" >&2
    exit 1
fi
if ! grep -q 'must not be a symlink' "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if find "$temperature_alt_source_symlink_target" -mindepth 1 -print -quit | grep -q .; then
    echo "Temperature alternate source probe wrote through symlinked output directory" >&2
    find "$temperature_alt_source_symlink_target" -mindepth 1 -maxdepth 2 -print >&2
    exit 1
fi
if zsh scripts/temperature-provider-alt-source-probe.sh --output-dir "$bag_mode_smoke_dir/temperature-alt-source-zsh" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature alternate source probe unexpectedly ran under explicit zsh" >&2
    exit 1
fi
if ! grep -q "requires bash" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_alt_source_fake_bin="$bag_mode_smoke_dir/temperature-alt-source-fakes"
mkdir -p "$temperature_alt_source_fake_bin"
cat >"$temperature_alt_source_fake_bin/ioreg" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *AppleSMCKeysEndpoint*)
    echo '+-o AppleSMCKeysEndpoint  <class AppleSMCKeysEndpoint>'
    echo '  | +-o AppleSmartBatteryManager  <class AppleSmartBatteryManager>'
    echo '  | | +-o AppleSmartBattery  <class AppleSmartBattery>'
    echo '  | |   "Temperature" = 3044'
    echo '  | |   "VirtualTemperature" = 3119'
    ;;
  *AppleARMPMUTempSensor*)
    echo '+-o AppleARMPMUTempSensor  <class AppleARMPMUTempSensor>'
    ;;
  *AppleEmbeddedNVMeTemperatureSensor*)
    echo '+-o AppleEmbeddedNVMeTemperatureSensor  <class AppleEmbeddedNVMeTemperatureSensor>'
    echo '  |   "Product" = "NAND CH0 temp"'
    ;;
  *AppleDieTempController*)
    echo '+-o AppleDieTempController  <class AppleDieTempController>'
    ;;
  *)
    echo '+-o AppleSmartBatteryManager  <class AppleSmartBatteryManager>'
    echo '  | +-o AppleSmartBattery  <class AppleSmartBattery>'
    echo '  |   "Temperature" = 3044'
    echo '  |   "VirtualTemperature" = 3119'
    echo '+-o AppleARMIODevice  <class AppleARMIODevice>'
    echo '    | | |   "die-id" = <00000000>'
    echo '    | |   |       |     |   "gyro-temp-table" = <02007c185400d3ff1a000000>'
    echo '    | |   |       |   +-o als-temp  <class AppleSPUHIDInterface, id 0x10000085f>'
    printf '    | |       "BatteryData" = {"Raw"=<'
    printf 'aa%.0s' {1..260}
    printf '>,"AverageTemperature"=264,"MaximumTemperature"=40}\n'
    echo '    | |   |       |     |   "Temperature" = <02007c185400d3ff1a000000>'
    echo '"IOReportGroupName"="Thermal"'
    echo '"Temperature" = 3046'
    echo '"VirtualTemperature" = 3139'
    echo 'CPU die temperature: 42 C'
    echo 'temp: 41'
    ;;
esac
EOF
chmod +x "$temperature_alt_source_fake_bin/ioreg"
cat >"$temperature_alt_source_fake_bin/hidutil" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "list" && "${2:-}" == "--ndjson" ]]; then
    cat <<'SERVICES'
{"Built-In":true,"VendorID":0,"type":"service","IOClass":"AppleSMCKeysEndpoint","Product":"PMU tdev1","PrimaryUsagePage":65280,"IORegistryEntryID":4294969528,"PrimaryUsage":5,"LocationID":1414541668,"ProductID":0}
{"Built-In":true,"VendorID":0,"type":"service","IOClass":"AppleSMCKeysEndpoint","Product":"PMU tdie7","PrimaryUsagePage":65280,"IORegistryEntryID":4294969950,"PrimaryUsage":5,"LocationID":1414543202,"ProductID":0}
{"Built-In":true,"VendorID":0,"type":"service","IOClass":"AppleEmbeddedNVMeTemperatureSensor","Product":"NAND CH0 temp","PrimaryUsagePage":65280,"IORegistryEntryID":4294970263,"PrimaryUsage":5,"LocationID":1414410350,"ProductID":0}
SERVICES
elif [[ "$1" == "list" ]]; then
    cat <<'SERVICES'
Services:
VendorID ProductID LocationID UsagePage Usage RegistryID  Transport            Class                                Product                            UserClass               Built-In
0x0      0x0       0x54503164 65280     5     0x1000008b8 (null)               AppleSMCKeysEndpoint                 PMU tdev1                          (null)                  1
0x0      0x0       0x54503762 65280     5     0x100000a5e (null)               AppleSMCKeysEndpoint                 PMU tdie7                          (null)                  1
0x0      0x0       0x544e306e 65280     5     0x100000b97 (null)               AppleEmbeddedNVMeTemperatureSensor   NAND CH0 temp                      (null)                  1
SERVICES
elif [[ "$1" == "dump" && "${2:-}" == "services" ]]; then
    cat <<'SERVICES'
            IOClass = AppleARMPMUTempSensor;
            Product = "PMU tdev1";
            PrimaryUsage = 5;
            PrimaryUsagePage = 65280;
            ReportInterval = 0;
            IOClass = AppleEmbeddedNVMeTemperatureSensor;
            Product = "NAND CH0 temp";
            PrimaryUsage = 5;
            PrimaryUsagePage = 65280;
            ReportInterval = 0;
SERVICES
else
    echo "unexpected hidutil arguments: $*" >&2
    exit 64
fi
EOF
chmod +x "$temperature_alt_source_fake_bin/hidutil"
temperature_alt_source_fake="$bag_mode_smoke_dir/temperature-alt-source-fake"
CLAWSHELL_TEMPERATURE_ALT_SOURCE_TIMEOUT_SECONDS=5 \
PATH="$temperature_alt_source_fake_bin:$PATH" \
    scripts/temperature-provider-alt-source-probe.sh --output-dir "$temperature_alt_source_fake" >/dev/null
for expected_key in \
    smcEndpointPresent=true \
    pmuTempSensorPresent=true \
    nvmeTempSensorPresent=true \
    dieTempControllerPresent=true \
    hidutilAvailable=true \
    hidPmuTemperatureInventoryPresent=true \
    hidPmuTemperatureServiceCount=2 \
    hidNvmeTemperatureInventoryPresent=true \
    hidTemperatureServiceDumpPresent=true \
    ioreportTemperatureLegendPresent=true \
    candidateSurfaceAvailable=true \
    numericTemperatureObserved=true \
    numericTemperatureCandidateCount=4 \
    numericTemperatureRawCandidateCount=8 \
    numericTemperatureRejectedBatteryContextCount=4 \
    numericTemperatureRejectionReason=none \
    helperOwned=false \
    numericCutoffSource=false \
    providerProofReady=false
do
    if ! grep -q "^$expected_key$" "$temperature_alt_source_fake/validation-config.txt"; then
        echo "Temperature alternate source probe missing fake field: $expected_key" >&2
        cat "$temperature_alt_source_fake/validation-config.txt" >&2
        exit 1
    fi
done
for expected_candidate in \
    '"Temperature" = 3046' \
    '"VirtualTemperature" = 3139' \
    'CPU die temperature: 42 C' \
    'temp: 41'
do
    if ! grep -q "$expected_candidate" "$temperature_alt_source_fake/evidence/numeric-temperature-candidates.txt"; then
        echo "Temperature alternate source probe did not retain fake numeric candidate line: $expected_candidate" >&2
        cat "$temperature_alt_source_fake/evidence/numeric-temperature-candidates.txt" >&2
        exit 1
    fi
done
if grep -Eq 'die-id|gyro-temp-table|als-temp|02007c|BatteryData|AverageTemperature|MaximumTemperature' "$temperature_alt_source_fake/evidence/numeric-temperature-candidates.txt"; then
    echo "Temperature alternate source probe retained non-scalar ID/table/blob candidates" >&2
    cat "$temperature_alt_source_fake/evidence/numeric-temperature-candidates.txt" >&2
    exit 1
fi
for rejected_candidate in \
    '"Temperature" = 3044' \
    '"VirtualTemperature" = 3119'
do
    if ! grep -q "$rejected_candidate" "$temperature_alt_source_fake/evidence/rejected-temperature-candidates.txt"; then
        echo "Temperature alternate source probe did not retain rejected battery-context candidate line: $rejected_candidate" >&2
        cat "$temperature_alt_source_fake/evidence/rejected-temperature-candidates.txt" >&2
        exit 1
    fi
done
if [[ "$(grep -Ec '3044|3119' "$temperature_alt_source_fake/evidence/rejected-temperature-candidates.txt")" -ne 4 ]]; then
    echo "Temperature alternate source probe did not reject battery-context candidates from both tree inventories" >&2
    cat "$temperature_alt_source_fake/evidence/rejected-temperature-candidates.txt" >&2
    exit 1
fi
if grep -Eq '3044|3119' "$temperature_alt_source_fake/evidence/numeric-temperature-candidates.txt"; then
    echo "Temperature alternate source probe promoted battery-context candidates" >&2
    cat "$temperature_alt_source_fake/evidence/numeric-temperature-candidates.txt" >&2
    exit 1
fi
if ! awk -F '\t' '$1 == "numeric-temperature-candidates" && $2 == "evidence" && $3 == "evidence/numeric-temperature-candidates.txt" { found = 1 } END { exit !found }' "$temperature_alt_source_fake/source-probe-manifest.tsv"; then
    echo "Temperature alternate source probe manifest did not attach numeric candidate evidence" >&2
    cat "$temperature_alt_source_fake/source-probe-manifest.tsv" >&2
    exit 1
fi
if ! awk -F '\t' '$1 == "hidutil-service-inventory" && $2 == "evidence" && $3 == "evidence/hidutil-service-inventory.txt" { found = 1 } END { exit !found }' "$temperature_alt_source_fake/source-probe-manifest.tsv"; then
    echo "Temperature alternate source probe manifest did not attach hidutil service inventory evidence" >&2
    cat "$temperature_alt_source_fake/source-probe-manifest.tsv" >&2
    exit 1
fi
if ! awk -F '\t' '$1 == "hidutil-temperature-service-ndjson" && $2 == "evidence" && $3 == "evidence/hidutil-temperature-service-ndjson.txt" { found = 1 } END { exit !found }' "$temperature_alt_source_fake/source-probe-manifest.tsv"; then
    echo "Temperature alternate source probe manifest did not attach hidutil temperature service NDJSON evidence" >&2
    cat "$temperature_alt_source_fake/source-probe-manifest.tsv" >&2
    exit 1
fi
if ! awk -F '\t' '$1 == "hidutil-temperature-service-dump" && $2 == "evidence" && $3 == "evidence/hidutil-temperature-service-dump.txt" { found = 1 } END { exit !found }' "$temperature_alt_source_fake/source-probe-manifest.tsv"; then
    echo "Temperature alternate source probe manifest did not attach hidutil temperature service dump evidence" >&2
    cat "$temperature_alt_source_fake/source-probe-manifest.tsv" >&2
    exit 1
fi
if ! awk -F '\t' '$1 == "nvme-temperature-sensor-inventory" && $2 == "evidence" && $3 == "evidence/nvme-temperature-sensor-inventory.txt" { found = 1 } END { exit !found }' "$temperature_alt_source_fake/source-probe-manifest.tsv"; then
    echo "Temperature alternate source probe manifest did not attach NVMe temperature sensor inventory evidence" >&2
    cat "$temperature_alt_source_fake/source-probe-manifest.tsv" >&2
    exit 1
fi
if ! awk -F '\t' '$1 == "rejected-temperature-candidates" && $2 == "evidence" && $3 == "evidence/rejected-temperature-candidates.txt" { found = 1 } END { exit !found }' "$temperature_alt_source_fake/source-probe-manifest.tsv"; then
    echo "Temperature alternate source probe manifest did not attach rejected candidate evidence" >&2
    cat "$temperature_alt_source_fake/source-probe-manifest.tsv" >&2
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

echo "==> temperature provider powermetrics proof attempt smoke"
temperature_powermetrics_attempt_dir="$bag_mode_smoke_dir/temperature-powermetrics-attempt"
scripts/temperature-provider-powermetrics-proof.sh --output-dir "$temperature_powermetrics_attempt_dir" >/dev/null
for required_file in \
    validation-config.txt \
    manual-result.md \
    provider-manifest.tsv \
    README.md \
    evidence/provider-command-or-api.txt \
    evidence/helper-ownership-context.txt \
    evidence/numeric-temperature-output.txt \
    evidence/numeric-temperature-output.status \
    evidence/permission-behavior.txt \
    evidence/no-user-visible-prompts.txt \
    evidence/timeout-enforcement.txt \
    evidence/processinfo-supplemental-signal.txt \
    evidence/logs.txt
do
    if [[ ! -f "$temperature_powermetrics_attempt_dir/$required_file" ]]; then
        echo "Temperature powermetrics proof attempt did not write expected file: $required_file" >&2
        exit 1
    fi
done
if ! grep -q '^providerProofReady=false$' "$temperature_powermetrics_attempt_dir/validation-config.txt"; then
    echo "Temperature powermetrics proof attempt overclaimed provider proof readiness" >&2
    cat "$temperature_powermetrics_attempt_dir/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^noUserVisiblePrompts=true$' "$temperature_powermetrics_attempt_dir/validation-config.txt"; then
    echo "Temperature powermetrics proof attempt did not record prompt-free mode" >&2
    cat "$temperature_powermetrics_attempt_dir/validation-config.txt" >&2
    exit 1
fi
if ! grep -q 'sudo -n' "$temperature_powermetrics_attempt_dir/evidence/no-user-visible-prompts.txt"; then
    echo "Temperature powermetrics proof attempt did not explain non-prompting sudo mode" >&2
    cat "$temperature_powermetrics_attempt_dir/evidence/no-user-visible-prompts.txt" >&2
    exit 1
fi
if ! awk -F '\t' '$1 == "permission-behavior" && $2 == "evidence" { found = 1 } END { exit !found }' "$temperature_powermetrics_attempt_dir/provider-manifest.tsv"; then
    echo "Temperature powermetrics proof attempt did not attach permission behavior evidence" >&2
    cat "$temperature_powermetrics_attempt_dir/provider-manifest.tsv" >&2
    exit 1
fi
for todo_row in \
    numeric-temperature-output \
    freshness-samples \
    active-cadence-samples \
    idle-cadence-samples \
    timeout-fail-closed \
    closed-bag-coverage-analysis \
    safety-contract-tests \
    unavailable-fail-closed \
    stale-fail-closed \
    permission-denied-fail-closed \
    parse-failed-fail-closed \
    helper-crashed-fail-closed \
    unsupported-hardware-fail-closed
do
    if ! awk -F '\t' -v check_id="$todo_row" '$1 == check_id && $2 == "TODO" { found = 1 } END { exit !found }' "$temperature_powermetrics_attempt_dir/provider-manifest.tsv"; then
        echo "Temperature powermetrics proof attempt should leave incomplete row as TODO: $todo_row" >&2
        cat "$temperature_powermetrics_attempt_dir/provider-manifest.tsv" >&2
        exit 1
    fi
done
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_powermetrics_attempt_dir/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted incomplete powermetrics proof attempt" >&2
    exit 1
fi
if ! grep -q "failClosedContract" "$bag_mode_smoke_error" && ! grep -q "required check must use status evidence" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_powermetrics_file_output="$bag_mode_smoke_dir/temperature-powermetrics-output-file"
touch "$temperature_powermetrics_file_output"
if scripts/temperature-provider-powermetrics-proof.sh --output-dir "$temperature_powermetrics_file_output" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature powermetrics proof attempt accepted an output path that is not a directory" >&2
    exit 1
fi
if ! grep -q 'not a directory' "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_powermetrics_non_empty="$bag_mode_smoke_dir/temperature-powermetrics-non-empty"
mkdir -p "$temperature_powermetrics_non_empty"
touch "$temperature_powermetrics_non_empty/existing"
if scripts/temperature-provider-powermetrics-proof.sh --output-dir "$temperature_powermetrics_non_empty" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature powermetrics proof attempt overwrote a non-empty output directory" >&2
    exit 1
fi
if ! grep -q 'Output directory is not empty' "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_powermetrics_bad_env="$bag_mode_smoke_dir/temperature-powermetrics-bad-env"
if CLAWSHELL_TEMPERATURE_PROOF_TIMEOUT_SECONDS=abc \
    scripts/temperature-provider-powermetrics-proof.sh --output-dir "$temperature_powermetrics_bad_env" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature powermetrics proof attempt accepted an invalid timeout value" >&2
    exit 1
fi
if [[ -e "$temperature_powermetrics_bad_env" ]]; then
    echo "Temperature powermetrics proof attempt created evidence for an invalid timeout value" >&2
    exit 1
fi
if zsh scripts/temperature-provider-powermetrics-proof.sh --output-dir "$bag_mode_smoke_dir/temperature-powermetrics-zsh" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature powermetrics proof attempt unexpectedly ran under explicit zsh" >&2
    exit 1
fi
if ! grep -q "requires bash" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

temperature_powermetrics_password_bin="$bag_mode_smoke_dir/temperature-powermetrics-password-fakes"
mkdir -p "$temperature_powermetrics_password_bin"
cat >"$temperature_powermetrics_password_bin/pmset" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-g batt" ]]; then
    echo "Now drawing from 'Battery Power'"
    exit 0
fi
exit 1
EOF
cat >"$temperature_powermetrics_password_bin/powermetrics" <<'EOF'
#!/usr/bin/env bash
echo "CPU die temperature: 42 C"
EOF
cat >"$temperature_powermetrics_password_bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" != "-n" ]]; then
    echo "sudo: refusing promptable invocation" >&2
    exit 99
fi
shift
echo "sudo: a password is required" >&2
exit 1
EOF
cat >"$temperature_powermetrics_password_bin/swift" <<'EOF'
#!/usr/bin/env bash
echo "thermalState=nominal"
EOF
chmod +x \
    "$temperature_powermetrics_password_bin/pmset" \
    "$temperature_powermetrics_password_bin/powermetrics" \
    "$temperature_powermetrics_password_bin/sudo" \
    "$temperature_powermetrics_password_bin/swift"
temperature_powermetrics_password="$bag_mode_smoke_dir/temperature-powermetrics-password-required"
PATH="$temperature_powermetrics_password_bin:$PATH" \
    scripts/temperature-provider-powermetrics-proof.sh --output-dir "$temperature_powermetrics_password" >/dev/null
if ! grep -q '^powermetricsPermissionState=sudoPasswordRequired$' "$temperature_powermetrics_password/validation-config.txt"; then
    echo "Temperature powermetrics proof attempt did not classify fake sudo password requirement" >&2
    cat "$temperature_powermetrics_password/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^helperOwned=false$' "$temperature_powermetrics_password/validation-config.txt"; then
    echo "Temperature powermetrics proof attempt overclaimed helper ownership for password-gated sudo" >&2
    cat "$temperature_powermetrics_password/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^numericCutoffSource=false$' "$temperature_powermetrics_password/validation-config.txt"; then
    echo "Temperature powermetrics proof attempt promoted password-gated output to cutoff source" >&2
    cat "$temperature_powermetrics_password/validation-config.txt" >&2
    exit 1
fi
if ! awk -F '\t' '$1 == "numeric-temperature-output" && $2 == "TODO" { found = 1 } END { exit !found }' "$temperature_powermetrics_password/provider-manifest.tsv"; then
    echo "Temperature powermetrics proof attempt attached numeric evidence for password-gated sudo" >&2
    cat "$temperature_powermetrics_password/provider-manifest.tsv" >&2
    exit 1
fi

temperature_powermetrics_timeout_bin="$bag_mode_smoke_dir/temperature-powermetrics-timeout-fakes"
mkdir -p "$temperature_powermetrics_timeout_bin"
cat >"$temperature_powermetrics_timeout_bin/pmset" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-g batt" ]]; then
    echo "Now drawing from 'Battery Power'"
    exit 0
fi
exit 1
EOF
cat >"$temperature_powermetrics_timeout_bin/powermetrics" <<'EOF'
#!/usr/bin/env bash
sleep 10
echo "CPU die temperature: 42 C"
EOF
cat >"$temperature_powermetrics_timeout_bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" != "-n" ]]; then
    echo "sudo: refusing promptable invocation" >&2
    exit 99
fi
shift
if [[ "${1:-}" == "true" ]]; then
    exit 0
fi
exec "$@"
EOF
cat >"$temperature_powermetrics_timeout_bin/swift" <<'EOF'
#!/usr/bin/env bash
echo "thermalState=nominal"
EOF
chmod +x \
    "$temperature_powermetrics_timeout_bin/pmset" \
    "$temperature_powermetrics_timeout_bin/powermetrics" \
    "$temperature_powermetrics_timeout_bin/sudo" \
    "$temperature_powermetrics_timeout_bin/swift"
temperature_powermetrics_timeout="$bag_mode_smoke_dir/temperature-powermetrics-timeout"
CLAWSHELL_TEMPERATURE_PROOF_TIMEOUT_SECONDS=1 \
PATH="$temperature_powermetrics_timeout_bin:$PATH" \
    scripts/temperature-provider-powermetrics-proof.sh --output-dir "$temperature_powermetrics_timeout" >/dev/null
if ! grep -q '^timedOut=true$' "$temperature_powermetrics_timeout/evidence/numeric-temperature-output.status"; then
    echo "Temperature powermetrics proof attempt did not record timed-out powermetrics" >&2
    cat "$temperature_powermetrics_timeout/evidence/numeric-temperature-output.status" >&2
    exit 1
fi
if ! grep -q '^powermetricsPermissionState=timedOut$' "$temperature_powermetrics_timeout/validation-config.txt"; then
    echo "Temperature powermetrics proof attempt did not classify timed-out powermetrics" >&2
    cat "$temperature_powermetrics_timeout/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^helperOwned=false$' "$temperature_powermetrics_timeout/validation-config.txt"; then
    echo "Temperature powermetrics proof attempt overclaimed helper ownership for timed-out sampling" >&2
    cat "$temperature_powermetrics_timeout/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^numericCutoffSource=false$' "$temperature_powermetrics_timeout/validation-config.txt"; then
    echo "Temperature powermetrics proof attempt promoted timed-out output to cutoff source" >&2
    cat "$temperature_powermetrics_timeout/validation-config.txt" >&2
    exit 1
fi
if pgrep -f "$temperature_powermetrics_timeout_bin/powermetrics" >/dev/null 2>&1; then
    echo "Temperature powermetrics proof attempt left fake powermetrics running after timeout" >&2
    pkill -f "$temperature_powermetrics_timeout_bin/powermetrics" >/dev/null 2>&1 || true
    exit 1
fi

temperature_powermetrics_fake_bin="$bag_mode_smoke_dir/temperature-powermetrics-fakes"
mkdir -p "$temperature_powermetrics_fake_bin"
cat >"$temperature_powermetrics_fake_bin/pmset" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-g batt" ]]; then
    echo "Now drawing from 'Battery Power'"
    echo " -InternalBattery-0 (id=1234567)"
    exit 0
fi
exit 1
EOF
cat >"$temperature_powermetrics_fake_bin/powermetrics" <<'EOF'
#!/usr/bin/env bash
echo "CPU die temperature: 42 C"
EOF
cat >"$temperature_powermetrics_fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" != "-n" ]]; then
    echo "sudo: refusing promptable invocation" >&2
    exit 99
fi
shift
if [[ "${1:-}" == "true" ]]; then
    exit 0
fi
exec "$@"
EOF
cat >"$temperature_powermetrics_fake_bin/swift" <<'EOF'
#!/usr/bin/env bash
echo "thermalState=nominal"
EOF
chmod +x \
    "$temperature_powermetrics_fake_bin/pmset" \
    "$temperature_powermetrics_fake_bin/powermetrics" \
    "$temperature_powermetrics_fake_bin/sudo" \
    "$temperature_powermetrics_fake_bin/swift"
temperature_powermetrics_available="$bag_mode_smoke_dir/temperature-powermetrics-available"
CLAWSHELL_TEMPERATURE_PROOF_TIMEOUT_SECONDS=5 \
PATH="$temperature_powermetrics_fake_bin:$PATH" \
    scripts/temperature-provider-powermetrics-proof.sh --output-dir "$temperature_powermetrics_available" >/dev/null
if ! grep -q '^helperOwned=false$' "$temperature_powermetrics_available/validation-config.txt"; then
    echo "Temperature powermetrics proof attempt overclaimed helper ownership for non-interactive sudo" >&2
    cat "$temperature_powermetrics_available/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^numericTemperatureObserved=true$' "$temperature_powermetrics_available/validation-config.txt"; then
    echo "Temperature powermetrics proof attempt did not record fake numeric diagnostic output" >&2
    cat "$temperature_powermetrics_available/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^numericCutoffSource=false$' "$temperature_powermetrics_available/validation-config.txt"; then
    echo "Temperature powermetrics proof attempt promoted diagnostic output to cutoff source" >&2
    cat "$temperature_powermetrics_available/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^powermetricsPermissionState=nonInteractiveSudoSucceeded$' "$temperature_powermetrics_available/validation-config.txt"; then
    echo "Temperature powermetrics proof attempt did not classify fake non-interactive sudo sampling" >&2
    cat "$temperature_powermetrics_available/validation-config.txt" >&2
    exit 1
fi
if ! awk -F '\t' '$1 == "numeric-temperature-output" && $2 == "evidence" { found = 1 } END { exit !found }' "$temperature_powermetrics_available/provider-manifest.tsv"; then
    echo "Temperature powermetrics proof attempt did not attach fake numeric output evidence" >&2
    cat "$temperature_powermetrics_available/provider-manifest.tsv" >&2
    exit 1
fi
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_powermetrics_available/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted incomplete fake powermetrics proof attempt" >&2
    exit 1
fi
if ! grep -q "active-cadence-samples" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

echo "==> temperature provider SMAppService proof harness smoke"
temperature_smappservice_provider_prepare="$bag_mode_smoke_dir/temperature-smappservice-provider-prepare"
scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_prepare" >/dev/null
for required_file in \
    validation-config.txt \
    manual-result.md \
    provider-manifest.tsv \
    README.md \
    ClawShellTemperatureProviderPrototype.app/Contents/MacOS/ClawShellTemperatureProviderPrototype \
    ClawShellTemperatureProviderPrototype.app/Contents/MacOS/ClawShellTemperatureProviderPrototypeDaemon \
    evidence/provider-command-or-api.txt \
    evidence/processinfo-supplemental-signal.txt \
    evidence/helper-ownership-model.txt \
    evidence/temperature-provider-status-before-approval.txt \
    evidence/no-user-visible-prompts.txt \
    evidence/logs.txt
do
    if [[ ! -f "$temperature_smappservice_provider_prepare/$required_file" ]]; then
        echo "Temperature SMAppService provider harness did not write expected file: $required_file" >&2
        exit 1
    fi
done
if ! grep -q '^helperInstallPath=smappservice$' "$temperature_smappservice_provider_prepare/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not record smappservice path" >&2
    cat "$temperature_smappservice_provider_prepare/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^helperOwned=false$' "$temperature_smappservice_provider_prepare/validation-config.txt"; then
    echo "Temperature SMAppService provider harness overclaimed helper ownership before approval" >&2
    cat "$temperature_smappservice_provider_prepare/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^providerProofReady=false$' "$temperature_smappservice_provider_prepare/validation-config.txt"; then
    echo "Temperature SMAppService provider harness overclaimed provider proof readiness" >&2
    cat "$temperature_smappservice_provider_prepare/validation-config.txt" >&2
    exit 1
fi
temperature_smappservice_provider_prepare_identity="$(awk -F= '$1 == "identitySuffix" { print $2; found = 1 } END { exit !found }' "$temperature_smappservice_provider_prepare/validation-config.txt")"
temperature_smappservice_provider_prepare_label="$(awk -F= '$1 == "helperLabel" { print $2; found = 1 } END { exit !found }' "$temperature_smappservice_provider_prepare/validation-config.txt")"
temperature_smappservice_provider_prepare_bundle="$(awk -F= '$1 == "appBundleIdentifier" { print $2; found = 1 } END { exit !found }' "$temperature_smappservice_provider_prepare/validation-config.txt")"
case "$temperature_smappservice_provider_prepare_identity" in
    h*) ;;
    *)
        echo "Temperature SMAppService provider harness did not record an auto identity suffix" >&2
        cat "$temperature_smappservice_provider_prepare/validation-config.txt" >&2
        exit 1
        ;;
esac
if [[ "$temperature_smappservice_provider_prepare_label" != "com.makeavish.ClawShell.TemperatureProviderPrototype.$temperature_smappservice_provider_prepare_identity.daemon" ]]; then
    echo "Temperature SMAppService provider harness did not derive helper label from identity suffix" >&2
    cat "$temperature_smappservice_provider_prepare/validation-config.txt" >&2
    exit 1
fi
if [[ "$temperature_smappservice_provider_prepare_bundle" != "com.makeavish.ClawShell.TemperatureProviderPrototype.$temperature_smappservice_provider_prepare_identity" ]]; then
    echo "Temperature SMAppService provider harness did not derive bundle id from identity suffix" >&2
    cat "$temperature_smappservice_provider_prepare/validation-config.txt" >&2
    exit 1
fi
if ! grep -q "$temperature_smappservice_provider_prepare_label" "$temperature_smappservice_provider_prepare/evidence/provider-command-or-api.txt"; then
    echo "Temperature SMAppService provider harness did not write unique helper label to LaunchDaemon plist" >&2
    cat "$temperature_smappservice_provider_prepare/evidence/provider-command-or-api.txt" >&2
    exit 1
fi
if ! grep -q "plistName=$temperature_smappservice_provider_prepare_label.plist" "$temperature_smappservice_provider_prepare/evidence/temperature-provider-status-before-approval.txt"; then
    echo "Temperature SMAppService provider harness did not point controller at unique helper plist" >&2
    cat "$temperature_smappservice_provider_prepare/evidence/temperature-provider-status-before-approval.txt" >&2
    exit 1
fi
if ! grep -q '^showInitialUsage=true$' "$temperature_smappservice_provider_prepare/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not record initial-usage powermetrics mode" >&2
    cat "$temperature_smappservice_provider_prepare/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^providerSource=powermetrics$' "$temperature_smappservice_provider_prepare/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not record default powermetrics provider source" >&2
    cat "$temperature_smappservice_provider_prepare/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^powermetricsSamplers=thermal$' "$temperature_smappservice_provider_prepare/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not record default powermetrics samplers" >&2
    cat "$temperature_smappservice_provider_prepare/validation-config.txt" >&2
    exit 1
fi
if ! grep -q -- '--show-initial-usage' "$temperature_smappservice_provider_prepare/evidence/provider-command-or-api.txt"; then
    echo "Temperature SMAppService provider harness did not wire --show-initial-usage into the LaunchDaemon command" >&2
    cat "$temperature_smappservice_provider_prepare/evidence/provider-command-or-api.txt" >&2
    exit 1
fi
if ! grep -q -- '--powermetrics-samplers' "$temperature_smappservice_provider_prepare/evidence/provider-command-or-api.txt"; then
    echo "Temperature SMAppService provider harness did not wire powermetrics sampler argument into the LaunchDaemon command" >&2
    cat "$temperature_smappservice_provider_prepare/evidence/provider-command-or-api.txt" >&2
    exit 1
fi
if ! grep -q -- '--provider-source' "$temperature_smappservice_provider_prepare/evidence/provider-command-or-api.txt" || \
    ! grep -q '"powermetrics"' "$temperature_smappservice_provider_prepare/evidence/provider-command-or-api.txt"; then
    echo "Temperature SMAppService provider harness did not wire default provider source into the LaunchDaemon command" >&2
    cat "$temperature_smappservice_provider_prepare/evidence/provider-command-or-api.txt" >&2
    exit 1
fi
if ! grep -q '"thermal"' "$temperature_smappservice_provider_prepare/evidence/provider-command-or-api.txt"; then
    echo "Temperature SMAppService provider harness did not wire default thermal sampler into the LaunchDaemon command" >&2
    cat "$temperature_smappservice_provider_prepare/evidence/provider-command-or-api.txt" >&2
    exit 1
fi
temperature_smappservice_provider_no_initial="$bag_mode_smoke_dir/temperature-smappservice-provider-no-initial"
CLAWSHELL_TEMPERATURE_PROVIDER_SHOW_INITIAL_USAGE=false \
    scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_no_initial" >/dev/null
if ! grep -q '^showInitialUsage=false$' "$temperature_smappservice_provider_no_initial/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not record disabled initial-usage mode" >&2
    cat "$temperature_smappservice_provider_no_initial/validation-config.txt" >&2
    exit 1
fi
if grep -q -- '--show-initial-usage' "$temperature_smappservice_provider_no_initial/evidence/provider-command-or-api.txt"; then
    echo "Temperature SMAppService provider harness wired --show-initial-usage while it was disabled" >&2
    cat "$temperature_smappservice_provider_no_initial/evidence/provider-command-or-api.txt" >&2
    exit 1
fi
temperature_smappservice_provider_no_initial_label="$(awk -F= '$1 == "helperLabel" { print $2; found = 1 } END { exit !found }' "$temperature_smappservice_provider_no_initial/validation-config.txt")"
if [[ "$temperature_smappservice_provider_no_initial_label" == "$temperature_smappservice_provider_prepare_label" ]]; then
    echo "Temperature SMAppService provider harness reused a helper label across distinct artifacts" >&2
    cat "$temperature_smappservice_provider_prepare/validation-config.txt" >&2
    cat "$temperature_smappservice_provider_no_initial/validation-config.txt" >&2
    exit 1
fi
temperature_smappservice_provider_all_samplers="$bag_mode_smoke_dir/temperature-smappservice-provider-all-samplers"
CLAWSHELL_TEMPERATURE_PROVIDER_POWERMETRICS_SAMPLERS=all \
    scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_all_samplers" >/dev/null
if ! grep -q '^powermetricsSamplers=all$' "$temperature_smappservice_provider_all_samplers/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not record explicit powermetrics samplers" >&2
    cat "$temperature_smappservice_provider_all_samplers/validation-config.txt" >&2
    exit 1
fi
if ! grep -q -- '--powermetrics-samplers' "$temperature_smappservice_provider_all_samplers/evidence/provider-command-or-api.txt" || \
    ! grep -q '"all"' "$temperature_smappservice_provider_all_samplers/evidence/provider-command-or-api.txt"; then
    echo "Temperature SMAppService provider harness did not wire explicit powermetrics samplers into the LaunchDaemon command" >&2
    cat "$temperature_smappservice_provider_all_samplers/evidence/provider-command-or-api.txt" >&2
    exit 1
fi
if ! grep -q 'let powermetricsSamplers = argumentValue(after: "--powermetrics-samplers") ?? "thermal"' "$temperature_smappservice_provider_all_samplers/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" || \
    ! grep -q 'let providerSource = argumentValue(after: "--provider-source") ?? "powermetrics"' "$temperature_smappservice_provider_all_samplers/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" || \
    ! grep -q 'var arguments = \["-n", "1", "-i", "\\(sampleRateMs)", "--samplers", powermetricsSamplers\]' "$temperature_smappservice_provider_all_samplers/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift"; then
    echo "Temperature SMAppService provider helper source did not consume the configured powermetrics sampler argument" >&2
    cat "$temperature_smappservice_provider_all_samplers/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" >&2
    exit 1
fi
temperature_smappservice_provider_ioreg_smc="$bag_mode_smoke_dir/temperature-smappservice-provider-ioreg-smc"
CLAWSHELL_TEMPERATURE_PROVIDER_SOURCE=ioreg-smc \
    CLAWSHELL_TEMPERATURE_PROVIDER_POWERMETRICS_SAMPLERS=smc \
    scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_ioreg_smc" >/dev/null
if ! grep -q '^providerSource=ioreg-smc$' "$temperature_smappservice_provider_ioreg_smc/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not record ioreg-smc provider source" >&2
    cat "$temperature_smappservice_provider_ioreg_smc/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^caseId=apple-silicon-ioreg-smc-smappservice$' "$temperature_smappservice_provider_ioreg_smc/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not use the ioreg-smc default case id" >&2
    cat "$temperature_smappservice_provider_ioreg_smc/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^powermetricsSamplers=not-used$' "$temperature_smappservice_provider_ioreg_smc/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not ignore stale powermetrics sampler settings for ioreg-smc" >&2
    cat "$temperature_smappservice_provider_ioreg_smc/validation-config.txt" >&2
    exit 1
fi
if ! grep -q -- '--provider-source' "$temperature_smappservice_provider_ioreg_smc/evidence/provider-command-or-api.txt" || \
    ! grep -q '"ioreg-smc"' "$temperature_smappservice_provider_ioreg_smc/evidence/provider-command-or-api.txt"; then
    echo "Temperature SMAppService provider harness did not wire ioreg-smc source into the LaunchDaemon command" >&2
    cat "$temperature_smappservice_provider_ioreg_smc/evidence/provider-command-or-api.txt" >&2
    exit 1
fi
if ! grep -q 'case "ioreg-smc"' "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" || \
    ! grep -q 'AppleSMCKeysEndpoint' "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift"; then
    echo "Temperature SMAppService provider helper source did not include ioreg-smc command path" >&2
    cat "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" >&2
    exit 1
fi
if ! grep -q 'readBoundedData' "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" || \
    ! grep -q 'outputByteLimit = 2_000_000' "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" || \
    ! grep -q 'read(upToCount: limit + 1)' "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" || \
    ! grep -q 'FileHandle(forWritingTo: stdoutURL)' "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" || \
    ! grep -q 'String(decoding: stdoutData.0, as: UTF8.self)' "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" || \
    ! grep -q 'stdoutBytes=\\(stdoutByteCount)' "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift"; then
    echo "Temperature SMAppService provider helper source did not include bounded file-backed output capture" >&2
    cat "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" >&2
    exit 1
fi
if ! grep -q 'ioregSMCNumericTemperatureAnalysis' "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" || \
    ! grep -q 'AppleSmartBatteryManager' "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" || \
    ! grep -q 'numericTemperatureRejectedBatteryContextCount' "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" || \
    ! grep -q 'ioreg-smc-battery-context-only' "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift"; then
    echo "Temperature SMAppService provider helper source did not reject ioreg-smc battery-context temperature candidates" >&2
    cat "$temperature_smappservice_provider_ioreg_smc/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" >&2
    exit 1
fi
temperature_smappservice_provider_ioreg_pmu="$bag_mode_smoke_dir/temperature-smappservice-provider-ioreg-pmu"
CLAWSHELL_TEMPERATURE_PROVIDER_SOURCE=ioreg-pmu \
    CLAWSHELL_TEMPERATURE_PROVIDER_POWERMETRICS_SAMPLERS=smc \
    scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_ioreg_pmu" >/dev/null
if ! grep -q '^providerSource=ioreg-pmu$' "$temperature_smappservice_provider_ioreg_pmu/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not record ioreg-pmu provider source" >&2
    cat "$temperature_smappservice_provider_ioreg_pmu/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^caseId=apple-silicon-ioreg-pmu-smappservice$' "$temperature_smappservice_provider_ioreg_pmu/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not use the ioreg-pmu default case id" >&2
    cat "$temperature_smappservice_provider_ioreg_pmu/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^powermetricsSamplers=not-used$' "$temperature_smappservice_provider_ioreg_pmu/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not ignore stale powermetrics sampler settings for ioreg-pmu" >&2
    cat "$temperature_smappservice_provider_ioreg_pmu/validation-config.txt" >&2
    exit 1
fi
if ! grep -q -- '--provider-source' "$temperature_smappservice_provider_ioreg_pmu/evidence/provider-command-or-api.txt" || \
    ! grep -q '"ioreg-pmu"' "$temperature_smappservice_provider_ioreg_pmu/evidence/provider-command-or-api.txt"; then
    echo "Temperature SMAppService provider harness did not wire ioreg-pmu source into the LaunchDaemon command" >&2
    cat "$temperature_smappservice_provider_ioreg_pmu/evidence/provider-command-or-api.txt" >&2
    exit 1
fi
if ! grep -q 'case "ioreg-pmu"' "$temperature_smappservice_provider_ioreg_pmu/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" || \
    ! grep -q 'AppleARMPMUTempSensor' "$temperature_smappservice_provider_ioreg_pmu/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift"; then
    echo "Temperature SMAppService provider helper source did not include ioreg-pmu command path" >&2
    cat "$temperature_smappservice_provider_ioreg_pmu/source-package/Sources/ClawShellTemperatureProviderPrototypeDaemon/main.swift" >&2
    exit 1
fi
temperature_smappservice_provider_multi_samplers="$bag_mode_smoke_dir/temperature-smappservice-provider-multi-samplers"
CLAWSHELL_TEMPERATURE_PROVIDER_POWERMETRICS_SAMPLERS=thermal,cpu_power \
    scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_multi_samplers" >/dev/null
if ! grep -q '^powermetricsSamplers=thermal,cpu_power$' "$temperature_smappservice_provider_multi_samplers/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not record comma-separated powermetrics samplers" >&2
    cat "$temperature_smappservice_provider_multi_samplers/validation-config.txt" >&2
    exit 1
fi
if ! grep -q -- '--powermetrics-samplers' "$temperature_smappservice_provider_multi_samplers/evidence/provider-command-or-api.txt" || \
    ! grep -q '"thermal,cpu_power"' "$temperature_smappservice_provider_multi_samplers/evidence/provider-command-or-api.txt"; then
    echo "Temperature SMAppService provider harness did not preserve comma-separated powermetrics samplers in the LaunchDaemon command" >&2
    cat "$temperature_smappservice_provider_multi_samplers/evidence/provider-command-or-api.txt" >&2
    exit 1
fi
temperature_smappservice_provider_manual_identity="$bag_mode_smoke_dir/temperature-smappservice-provider-manual-identity"
CLAWSHELL_TEMPERATURE_PROVIDER_ID_SUFFIX=manual01 \
    scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_manual_identity" >/dev/null
if ! grep -q '^identitySuffix=manual01$' "$temperature_smappservice_provider_manual_identity/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not record explicit identity suffix" >&2
    cat "$temperature_smappservice_provider_manual_identity/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^helperLabel=com.makeavish.ClawShell.TemperatureProviderPrototype.manual01.daemon$' "$temperature_smappservice_provider_manual_identity/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not derive helper label from explicit identity suffix" >&2
    cat "$temperature_smappservice_provider_manual_identity/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^appBundleIdentifier=com.makeavish.ClawShell.TemperatureProviderPrototype.manual01$' "$temperature_smappservice_provider_manual_identity/validation-config.txt"; then
    echo "Temperature SMAppService provider harness did not derive bundle id from explicit identity suffix" >&2
    cat "$temperature_smappservice_provider_manual_identity/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^registerAttempted=false$' "$temperature_smappservice_provider_prepare/validation-config.txt"; then
    echo "Temperature SMAppService provider harness unexpectedly attempted registration in default mode" >&2
    cat "$temperature_smappservice_provider_prepare/validation-config.txt" >&2
    exit 1
fi
for todo_row in \
    helper-ownership-context \
    numeric-temperature-output \
    timeout-enforcement \
    permission-behavior \
    freshness-samples \
    active-cadence-samples \
    idle-cadence-samples
do
    if ! awk -F '\t' -v check_id="$todo_row" '$1 == check_id && $2 == "TODO" { found = 1 } END { exit !found }' "$temperature_smappservice_provider_prepare/provider-manifest.tsv"; then
        echo "Temperature SMAppService provider harness should leave incomplete row as TODO: $todo_row" >&2
        cat "$temperature_smappservice_provider_prepare/provider-manifest.tsv" >&2
        exit 1
    fi
done
if scripts/temperature-provider-proof-verify.sh --manifest "$temperature_smappservice_provider_prepare/provider-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature provider proof verifier accepted incomplete SMAppService provider proof attempt" >&2
    exit 1
fi
if ! grep -q "helperOwned" "$bag_mode_smoke_error" && ! grep -q "required check must use status evidence" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_smappservice_provider_register_without_ack="$bag_mode_smoke_dir/temperature-smappservice-provider-register-without-ack"
if scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_register_without_ack" --register >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness allowed register without acknowledgement" >&2
    exit 1
fi
if ! grep -q -- "--i-understand-this-registers-provider" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_smappservice_provider_register_missing="$bag_mode_smoke_dir/temperature-smappservice-provider-register-missing"
if scripts/temperature-provider-smappservice-proof.sh \
    --output-dir "$temperature_smappservice_provider_register_missing" \
    --register \
    --i-understand-this-registers-provider >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness allowed register without a prepared artifact" >&2
    exit 1
fi
if ! grep -q "existing artifact directory" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_smappservice_provider_unregister_without_ack="$bag_mode_smoke_dir/temperature-smappservice-provider-unregister-without-ack"
if scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_unregister_without_ack" --capture-unregister >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness allowed unregister capture without acknowledgement" >&2
    exit 1
fi
if ! grep -q -- "--i-understand-this-registers-provider" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_prepare" --capture-post-approval --capture-unregister --i-understand-this-registers-provider >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness allowed combined append capture modes" >&2
    exit 1
fi
if ! grep -q "Use only one" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_smappservice_provider_missing_label="$bag_mode_smoke_dir/temperature-smappservice-provider-missing-label"
cp -R "$temperature_smappservice_provider_prepare" "$temperature_smappservice_provider_missing_label"
grep -v '^helperLabel=' "$temperature_smappservice_provider_missing_label/validation-config.txt" >"$temperature_smappservice_provider_missing_label/validation-config.tmp"
mv "$temperature_smappservice_provider_missing_label/validation-config.tmp" "$temperature_smappservice_provider_missing_label/validation-config.txt"
if scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_missing_label" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness invented helper label for existing artifact" >&2
    exit 1
fi
if ! grep -q "missing required helperLabel" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_smappservice_provider_missing_plist="$bag_mode_smoke_dir/temperature-smappservice-provider-missing-plist"
cp -R "$temperature_smappservice_provider_prepare" "$temperature_smappservice_provider_missing_plist"
temperature_smappservice_provider_missing_plist_label="$(awk -F= '$1 == "helperLabel" { print $2; found = 1 } END { exit !found }' "$temperature_smappservice_provider_missing_plist/validation-config.txt")"
rm -f "$temperature_smappservice_provider_missing_plist/ClawShellTemperatureProviderPrototype.app/Contents/Library/LaunchDaemons/$temperature_smappservice_provider_missing_plist_label.plist"
if scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_missing_plist" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness accepted existing artifact without LaunchDaemon plist" >&2
    exit 1
fi
if ! grep -q "missing required artifact file path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_smappservice_provider_mismatched_plist_label="$bag_mode_smoke_dir/temperature-smappservice-provider-mismatched-plist-label"
cp -R "$temperature_smappservice_provider_prepare" "$temperature_smappservice_provider_mismatched_plist_label"
temperature_smappservice_provider_mismatched_plist_label_value="$(awk -F= '$1 == "helperLabel" { print $2; found = 1 } END { exit !found }' "$temperature_smappservice_provider_mismatched_plist_label/validation-config.txt")"
plutil -replace Label -string "com.makeavish.ClawShell.TemperatureProviderPrototype.stale.daemon" \
    "$temperature_smappservice_provider_mismatched_plist_label/ClawShellTemperatureProviderPrototype.app/Contents/Library/LaunchDaemons/$temperature_smappservice_provider_mismatched_plist_label_value.plist"
if scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_mismatched_plist_label" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness accepted existing artifact with mismatched LaunchDaemon Label" >&2
    exit 1
fi
if ! grep -q "LaunchDaemon Label" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_smappservice_provider_register_fake="$bag_mode_smoke_dir/temperature-smappservice-provider-register-fake"
cp -R "$temperature_smappservice_provider_prepare" "$temperature_smappservice_provider_register_fake"
temperature_smappservice_provider_register_fake_label="$(awk -F= '$1 == "helperLabel" { print $2; found = 1 } END { exit !found }' "$temperature_smappservice_provider_register_fake/validation-config.txt")"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'command="${1:-status}"'
    printf '%s\n' 'echo "command=$command"'
    printf 'echo "plistName=%s.plist"\n' "$temperature_smappservice_provider_register_fake_label"
    printf '%s\n' 'case "$command" in'
    printf '%s\n' '  register)'
    printf '%s\n' '    echo "statusBeforeRaw=3"'
    printf '%s\n' '    echo "statusBeforeDescription=SMAppServiceStatus(rawValue: 3)"'
    printf '%s\n' '    echo "registerResult=success"'
    printf '%s\n' '    echo "statusAfterRaw=2"'
    printf '%s\n' '    echo "statusAfterDescription=SMAppServiceStatus(rawValue: 2)"'
    printf '%s\n' '    ;;'
    printf '%s\n' '  status)'
    printf '%s\n' '    echo "statusBeforeRaw=2"'
    printf '%s\n' '    echo "statusBeforeDescription=SMAppServiceStatus(rawValue: 2)"'
    printf '%s\n' '    echo "statusAfterRaw=2"'
    printf '%s\n' '    echo "statusAfterDescription=SMAppServiceStatus(rawValue: 2)"'
    printf '%s\n' '    ;;'
    printf '%s\n' '  *) exit 64 ;;'
    printf '%s\n' 'esac'
} >"$temperature_smappservice_provider_register_fake/ClawShellTemperatureProviderPrototype.app/Contents/MacOS/ClawShellTemperatureProviderPrototype"
printf '#!/usr/bin/env bash\nexit 0\n' >"$temperature_smappservice_provider_register_fake/ClawShellTemperatureProviderPrototype.app/Contents/MacOS/ClawShellTemperatureProviderPrototypeDaemon"
chmod +x "$temperature_smappservice_provider_register_fake/ClawShellTemperatureProviderPrototype.app/Contents/MacOS/ClawShellTemperatureProviderPrototype" \
    "$temperature_smappservice_provider_register_fake/ClawShellTemperatureProviderPrototype.app/Contents/MacOS/ClawShellTemperatureProviderPrototypeDaemon"
scripts/temperature-provider-smappservice-proof.sh \
    --output-dir "$temperature_smappservice_provider_register_fake" \
    --register \
    --i-understand-this-registers-provider >/dev/null
if ! grep -q '^registerAttempted=true$' "$temperature_smappservice_provider_register_fake/validation-config.txt"; then
    echo "Temperature SMAppService provider register capture did not update registerAttempted" >&2
    cat "$temperature_smappservice_provider_register_fake/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^registerCaptureAttempted=true$' "$temperature_smappservice_provider_register_fake/validation-config.txt"; then
    echo "Temperature SMAppService provider register capture did not update registerCaptureAttempted" >&2
    cat "$temperature_smappservice_provider_register_fake/validation-config.txt" >&2
    exit 1
fi
for register_capture in \
    temperature-provider-status-before-register \
    provider-register \
    temperature-provider-status-after-register
do
    if [[ ! -s "$temperature_smappservice_provider_register_fake/evidence/$register_capture.txt" ]]; then
        echo "Temperature SMAppService provider register capture missing evidence: $register_capture" >&2
        exit 1
    fi
    if [[ ! -s "$temperature_smappservice_provider_register_fake/evidence/$register_capture.status" ]]; then
        echo "Temperature SMAppService provider register capture missing status: $register_capture" >&2
        exit 1
    fi
done
if ! grep -q "plistName=$temperature_smappservice_provider_register_fake_label.plist" "$temperature_smappservice_provider_register_fake/evidence/temperature-provider-status-before-register.txt"; then
    echo "Temperature SMAppService provider register capture did not preflight matching controller plist" >&2
    cat "$temperature_smappservice_provider_register_fake/evidence/temperature-provider-status-before-register.txt" >&2
    exit 1
fi
if [[ ! -s "$temperature_smappservice_provider_register_fake/register-capture.md" ]]; then
    echo "Temperature SMAppService provider register capture missing summary" >&2
    exit 1
fi
temperature_smappservice_provider_register_symlink_executable="$bag_mode_smoke_dir/temperature-smappservice-provider-register-symlink-executable"
cp -R "$temperature_smappservice_provider_register_fake" "$temperature_smappservice_provider_register_symlink_executable"
rm -f "$temperature_smappservice_provider_register_symlink_executable/ClawShellTemperatureProviderPrototype.app/Contents/MacOS/ClawShellTemperatureProviderPrototype"
ln -s /bin/echo "$temperature_smappservice_provider_register_symlink_executable/ClawShellTemperatureProviderPrototype.app/Contents/MacOS/ClawShellTemperatureProviderPrototype"
if scripts/temperature-provider-smappservice-proof.sh \
    --output-dir "$temperature_smappservice_provider_register_symlink_executable" \
    --register \
    --i-understand-this-registers-provider >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider register capture ran a symlinked controller path" >&2
    exit 1
fi
if ! grep -q "regular executable artifact path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_smappservice_provider_register_symlink_summary="$bag_mode_smoke_dir/temperature-smappservice-provider-register-symlink-summary"
cp -R "$temperature_smappservice_provider_register_fake" "$temperature_smappservice_provider_register_symlink_summary"
rm -f "$temperature_smappservice_provider_register_symlink_summary/register-capture.md"
ln -s /etc/hosts "$temperature_smappservice_provider_register_symlink_summary/register-capture.md"
if scripts/temperature-provider-smappservice-proof.sh \
    --output-dir "$temperature_smappservice_provider_register_symlink_summary" \
    --register \
    --i-understand-this-registers-provider >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider register capture followed a symlinked summary path" >&2
    exit 1
fi
if ! grep -q "requires regular capture path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_smappservice_provider_capture_missing="$bag_mode_smoke_dir/temperature-smappservice-provider-capture-missing"
if scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_capture_missing" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness allowed post-approval capture without an existing artifact" >&2
    exit 1
fi
if ! grep -q "existing artifact directory" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_smappservice_provider_file="$bag_mode_smoke_dir/temperature-smappservice-provider-file"
touch "$temperature_smappservice_provider_file"
if scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_file" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness accepted an output path that is not a directory" >&2
    exit 1
fi
if ! grep -q "not a directory" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_smappservice_provider_non_empty="$bag_mode_smoke_dir/temperature-smappservice-provider-non-empty"
mkdir -p "$temperature_smappservice_provider_non_empty"
touch "$temperature_smappservice_provider_non_empty/existing"
if scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_non_empty" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness overwrote a non-empty output directory" >&2
    exit 1
fi
if ! grep -q "Output directory is not empty" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
temperature_smappservice_provider_bad_env="$bag_mode_smoke_dir/temperature-smappservice-provider-bad-env"
if CLAWSHELL_TEMPERATURE_PROVIDER_TIMEOUT_SECONDS=abc \
    scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_bad_env" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness accepted an invalid timeout value" >&2
    exit 1
fi
if [[ -e "$temperature_smappservice_provider_bad_env" ]]; then
    echo "Temperature SMAppService provider harness created evidence for an invalid timeout value" >&2
    exit 1
fi
temperature_smappservice_provider_bad_bool="$bag_mode_smoke_dir/temperature-smappservice-provider-bad-bool"
if CLAWSHELL_TEMPERATURE_PROVIDER_SHOW_INITIAL_USAGE=maybe \
    scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_bad_bool" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness accepted an invalid initial-usage flag" >&2
    exit 1
fi
if ! grep -q "CLAWSHELL_TEMPERATURE_PROVIDER_SHOW_INITIAL_USAGE must be true or false" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if [[ -e "$temperature_smappservice_provider_bad_bool" ]]; then
    echo "Temperature SMAppService provider harness created evidence for an invalid initial-usage flag" >&2
    exit 1
fi
temperature_smappservice_provider_bad_source="$bag_mode_smoke_dir/temperature-smappservice-provider-bad-source"
if CLAWSHELL_TEMPERATURE_PROVIDER_SOURCE=smc \
    scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_bad_source" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness accepted an invalid provider source" >&2
    exit 1
fi
if ! grep -q "CLAWSHELL_TEMPERATURE_PROVIDER_SOURCE must be one of: powermetrics, ioreg-smc, ioreg-pmu" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if [[ -e "$temperature_smappservice_provider_bad_source" ]]; then
    echo "Temperature SMAppService provider harness created evidence for an invalid provider source" >&2
    exit 1
fi
temperature_smappservice_provider_bad_suffix="$bag_mode_smoke_dir/temperature-smappservice-provider-bad-suffix"
if CLAWSHELL_TEMPERATURE_PROVIDER_ID_SUFFIX=bad-suffix \
    scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_bad_suffix" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness accepted an invalid identity suffix" >&2
    exit 1
fi
if ! grep -q "CLAWSHELL_TEMPERATURE_PROVIDER_ID_SUFFIX must start with a letter" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if [[ -e "$temperature_smappservice_provider_bad_suffix" ]]; then
    echo "Temperature SMAppService provider harness created evidence for an invalid identity suffix" >&2
    exit 1
fi
temperature_smappservice_provider_bad_samplers="$bag_mode_smoke_dir/temperature-smappservice-provider-bad-samplers"
if CLAWSHELL_TEMPERATURE_PROVIDER_POWERMETRICS_SAMPLERS=smc \
    scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_bad_samplers" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness accepted an unsupported powermetrics sampler" >&2
    exit 1
fi
if ! grep -q "unsupported powermetrics sampler: smc" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if [[ -e "$temperature_smappservice_provider_bad_samplers" ]]; then
    echo "Temperature SMAppService provider harness created evidence for an invalid powermetrics sampler" >&2
    exit 1
fi
temperature_smappservice_provider_newline_samplers="$bag_mode_smoke_dir/temperature-smappservice-provider-newline-samplers"
if env $'CLAWSHELL_TEMPERATURE_PROVIDER_POWERMETRICS_SAMPLERS=thermal\nsmc' \
    scripts/temperature-provider-smappservice-proof.sh --output-dir "$temperature_smappservice_provider_newline_samplers" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness accepted a newline-delimited powermetrics sampler value" >&2
    exit 1
fi
if ! grep -q "must not contain control characters" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if [[ -e "$temperature_smappservice_provider_newline_samplers" ]]; then
    echo "Temperature SMAppService provider harness created evidence for a newline-delimited powermetrics sampler" >&2
    exit 1
fi
if zsh scripts/temperature-provider-smappservice-proof.sh --output-dir "$bag_mode_smoke_dir/temperature-smappservice-provider-zsh" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Temperature SMAppService provider harness unexpectedly ran under explicit zsh" >&2
    exit 1
fi
if ! grep -q "requires bash" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
CLAWSHELL_TEMPERATURE_PROVIDER_LOG_LAST=1m \
    scripts/temperature-provider-smappservice-proof.sh \
    --output-dir "$temperature_smappservice_provider_prepare" \
    --capture-post-approval >/dev/null
if ! grep -q '^postApprovalCaptureAttempted=true$' "$temperature_smappservice_provider_prepare/validation-config.txt"; then
    echo "Temperature SMAppService provider post-approval capture did not update validation config" >&2
    cat "$temperature_smappservice_provider_prepare/validation-config.txt" >&2
    exit 1
fi
for post_approval_capture in \
    temperature-provider-status-after-approval \
    helper-ownership-context \
    numeric-temperature-output \
    permission-behavior \
    timeout-enforcement \
    launchctl-status \
    logs
do
    if [[ ! -s "$temperature_smappservice_provider_prepare/evidence/$post_approval_capture.txt" ]]; then
        echo "Temperature SMAppService provider post-approval capture missing evidence: $post_approval_capture" >&2
        exit 1
    fi
    if [[ ! -s "$temperature_smappservice_provider_prepare/evidence/$post_approval_capture.status" ]]; then
        echo "Temperature SMAppService provider post-approval capture missing status: $post_approval_capture" >&2
        exit 1
    fi
done
for unpromoted_capture_row in \
    helper-ownership-context \
    numeric-temperature-output \
    timeout-enforcement \
    permission-behavior
do
    if ! awk -F '\t' -v check_id="$unpromoted_capture_row" '$1 == check_id && $2 == "TODO" { found = 1 } END { exit !found }' "$temperature_smappservice_provider_prepare/provider-manifest.tsv"; then
        echo "Temperature SMAppService provider post-approval capture should not auto-promote row: $unpromoted_capture_row" >&2
        cat "$temperature_smappservice_provider_prepare/provider-manifest.tsv" >&2
        exit 1
    fi
done
temperature_smappservice_provider_runtime_success="$bag_mode_smoke_dir/temperature-smappservice-provider-runtime-success"
cp -R "$temperature_smappservice_provider_prepare" "$temperature_smappservice_provider_runtime_success"
cat >"$temperature_smappservice_provider_runtime_success/runtime/provider.log" <<'EOF'
event=temperature-provider-sample
uid=0
euid=0
providerSource=powermetrics
timedOut=false
exitCode=0
helperOwned=true
numericTemperatureObserved=true
powermetricsSamplers=thermal
EOF
cat >"$temperature_smappservice_provider_runtime_success/runtime/numeric-temperature-output.txt" <<'EOF'
$ /usr/bin/powermetrics --show-initial-usage -n 1 -i 1000 --samplers thermal
CPU die temperature: 42 C
--- stderr ---
EOF
cat >"$temperature_smappservice_provider_runtime_success/runtime/numeric-temperature-output.status" <<'EOF'
command=/usr/bin/powermetrics --show-initial-usage -n 1 -i 1000 --samplers thermal
durationSeconds=1
timeoutSeconds=1
showInitialUsage=true
powermetricsSamplers=thermal
timedOut=false
exitCode=0
helperOwned=true
numericTemperatureObserved=true
runError=none
EOF
CLAWSHELL_TEMPERATURE_PROVIDER_LOG_LAST=1m \
    scripts/temperature-provider-smappservice-proof.sh \
    --output-dir "$temperature_smappservice_provider_runtime_success" \
    --capture-post-approval >/dev/null
for successful_runtime_capture in \
    helper-ownership-context \
    numeric-temperature-output \
    permission-behavior \
    timeout-enforcement
do
    if ! grep -q '^exitCode=0$' "$temperature_smappservice_provider_runtime_success/evidence/$successful_runtime_capture.status"; then
        echo "Temperature SMAppService provider post-approval capture did not accept present runtime source: $successful_runtime_capture" >&2
        cat "$temperature_smappservice_provider_runtime_success/evidence/$successful_runtime_capture.status" >&2
        cat "$temperature_smappservice_provider_runtime_success/evidence/$successful_runtime_capture.txt" >&2
        exit 1
    fi
done
if ! grep -q 'helperOwned=true' "$temperature_smappservice_provider_runtime_success/evidence/helper-ownership-context.txt"; then
    echo "Temperature SMAppService provider post-approval capture missed helper-owned runtime context" >&2
    cat "$temperature_smappservice_provider_runtime_success/evidence/helper-ownership-context.txt" >&2
    exit 1
fi
if ! grep -q 'CPU die temperature: 42 C' "$temperature_smappservice_provider_runtime_success/evidence/numeric-temperature-output.txt"; then
    echo "Temperature SMAppService provider post-approval capture missed numeric runtime output" >&2
    cat "$temperature_smappservice_provider_runtime_success/evidence/numeric-temperature-output.txt" >&2
    exit 1
fi
for status_capture in \
    permission-behavior \
    timeout-enforcement
do
    for required_status_field in \
        'timedOut=false' \
        'exitCode=0' \
        'helperOwned=true' \
        'showInitialUsage=true' \
        'powermetricsSamplers=thermal' \
        'numericTemperatureObserved=true'
    do
        if ! grep -q "$required_status_field" "$temperature_smappservice_provider_runtime_success/evidence/$status_capture.txt"; then
            echo "Temperature SMAppService provider post-approval capture missed runtime status field: $required_status_field in $status_capture" >&2
            cat "$temperature_smappservice_provider_runtime_success/evidence/$status_capture.txt" >&2
            exit 1
        fi
    done
done
temperature_smappservice_provider_symlink_source="$bag_mode_smoke_dir/temperature-smappservice-provider-symlink-source"
cp -R "$temperature_smappservice_provider_prepare" "$temperature_smappservice_provider_symlink_source"
rm -f "$temperature_smappservice_provider_symlink_source/runtime/numeric-temperature-output.txt"
ln -s /etc/hosts "$temperature_smappservice_provider_symlink_source/runtime/numeric-temperature-output.txt"
CLAWSHELL_TEMPERATURE_PROVIDER_LOG_LAST=1m \
    scripts/temperature-provider-smappservice-proof.sh \
    --output-dir "$temperature_smappservice_provider_symlink_source" \
    --capture-post-approval >/dev/null
if ! grep -q "symlinkSource=" "$temperature_smappservice_provider_symlink_source/evidence/numeric-temperature-output.txt"; then
    echo "Temperature SMAppService provider post-approval capture followed a symlinked runtime source" >&2
    cat "$temperature_smappservice_provider_symlink_source/evidence/numeric-temperature-output.txt" >&2
    exit 1
fi
if ! grep -q '^exitCode=1$' "$temperature_smappservice_provider_symlink_source/evidence/numeric-temperature-output.status"; then
    echo "Temperature SMAppService provider post-approval capture did not fail symlinked runtime source" >&2
    cat "$temperature_smappservice_provider_symlink_source/evidence/numeric-temperature-output.status" >&2
    exit 1
fi
temperature_smappservice_provider_non_regular_source="$bag_mode_smoke_dir/temperature-smappservice-provider-non-regular-source"
cp -R "$temperature_smappservice_provider_prepare" "$temperature_smappservice_provider_non_regular_source"
rm -f "$temperature_smappservice_provider_non_regular_source/runtime/numeric-temperature-output.txt"
mkdir "$temperature_smappservice_provider_non_regular_source/runtime/numeric-temperature-output.txt"
CLAWSHELL_TEMPERATURE_PROVIDER_LOG_LAST=1m \
    scripts/temperature-provider-smappservice-proof.sh \
    --output-dir "$temperature_smappservice_provider_non_regular_source" \
    --capture-post-approval >/dev/null
if ! grep -q "nonRegularSource=" "$temperature_smappservice_provider_non_regular_source/evidence/numeric-temperature-output.txt"; then
    echo "Temperature SMAppService provider post-approval capture read a non-regular runtime source" >&2
    cat "$temperature_smappservice_provider_non_regular_source/evidence/numeric-temperature-output.txt" >&2
    exit 1
fi
if ! grep -q '^exitCode=1$' "$temperature_smappservice_provider_non_regular_source/evidence/numeric-temperature-output.status"; then
    echo "Temperature SMAppService provider post-approval capture did not fail non-regular runtime source" >&2
    cat "$temperature_smappservice_provider_non_regular_source/evidence/numeric-temperature-output.status" >&2
    exit 1
fi
temperature_smappservice_provider_unregister_fake="$bag_mode_smoke_dir/temperature-smappservice-provider-unregister-fake"
cp -R "$temperature_smappservice_provider_prepare" "$temperature_smappservice_provider_unregister_fake"
temperature_smappservice_provider_unregister_fake_label="$(awk -F= '$1 == "helperLabel" { print $2; found = 1 } END { exit !found }' "$temperature_smappservice_provider_unregister_fake/validation-config.txt")"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'command="${1:-status}"'
    printf '%s\n' 'echo "command=$command"'
    printf 'echo "plistName=%s.plist"\n' "$temperature_smappservice_provider_unregister_fake_label"
    printf '%s\n' 'case "$command" in'
    printf '%s\n' '  unregister)'
    printf '%s\n' '    echo "statusBeforeRaw=1"'
    printf '%s\n' '    echo "statusBeforeDescription=SMAppServiceStatus(rawValue: 1)"'
    printf '%s\n' '    echo "unregisterResult=success"'
    printf '%s\n' '    echo "statusAfterRaw=0"'
    printf '%s\n' '    echo "statusAfterDescription=SMAppServiceStatus(rawValue: 0)"'
    printf '%s\n' '    ;;'
    printf '%s\n' '  status)'
    printf '%s\n' '    echo "statusBeforeRaw=0"'
    printf '%s\n' '    echo "statusBeforeDescription=SMAppServiceStatus(rawValue: 0)"'
    printf '%s\n' '    echo "statusAfterRaw=0"'
    printf '%s\n' '    echo "statusAfterDescription=SMAppServiceStatus(rawValue: 0)"'
    printf '%s\n' '    ;;'
    printf '%s\n' '  *) exit 64 ;;'
    printf '%s\n' 'esac'
} >"$temperature_smappservice_provider_unregister_fake/ClawShellTemperatureProviderPrototype.app/Contents/MacOS/ClawShellTemperatureProviderPrototype"
printf '#!/usr/bin/env bash\nexit 0\n' >"$temperature_smappservice_provider_unregister_fake/ClawShellTemperatureProviderPrototype.app/Contents/MacOS/ClawShellTemperatureProviderPrototypeDaemon"
chmod +x "$temperature_smappservice_provider_unregister_fake/ClawShellTemperatureProviderPrototype.app/Contents/MacOS/ClawShellTemperatureProviderPrototype" \
    "$temperature_smappservice_provider_unregister_fake/ClawShellTemperatureProviderPrototype.app/Contents/MacOS/ClawShellTemperatureProviderPrototypeDaemon"
CLAWSHELL_TEMPERATURE_PROVIDER_LOG_LAST=1m \
    scripts/temperature-provider-smappservice-proof.sh \
    --output-dir "$temperature_smappservice_provider_unregister_fake" \
    --capture-unregister \
    --i-understand-this-registers-provider >/dev/null
if ! grep -q '^unregisterAttempted=true$' "$temperature_smappservice_provider_unregister_fake/validation-config.txt"; then
    echo "Temperature SMAppService provider unregister capture did not update unregisterAttempted" >&2
    cat "$temperature_smappservice_provider_unregister_fake/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^unregisterCaptureAttempted=true$' "$temperature_smappservice_provider_unregister_fake/validation-config.txt"; then
    echo "Temperature SMAppService provider unregister capture did not update unregisterCaptureAttempted" >&2
    cat "$temperature_smappservice_provider_unregister_fake/validation-config.txt" >&2
    exit 1
fi
for unregister_capture in \
    temperature-provider-status-before-unregister \
    provider-unregister \
    temperature-provider-status-after-unregister \
    launchctl-status-after-unregister \
    logs-after-unregister
do
    if [[ ! -s "$temperature_smappservice_provider_unregister_fake/evidence/$unregister_capture.txt" ]]; then
        echo "Temperature SMAppService provider unregister capture missing evidence: $unregister_capture" >&2
        exit 1
    fi
    if [[ ! -s "$temperature_smappservice_provider_unregister_fake/evidence/$unregister_capture.status" ]]; then
        echo "Temperature SMAppService provider unregister capture missing status: $unregister_capture" >&2
        exit 1
    fi
done
if ! grep -q "plistName=$temperature_smappservice_provider_unregister_fake_label.plist" "$temperature_smappservice_provider_unregister_fake/evidence/temperature-provider-status-before-unregister.txt"; then
    echo "Temperature SMAppService provider unregister capture did not preflight matching controller plist" >&2
    cat "$temperature_smappservice_provider_unregister_fake/evidence/temperature-provider-status-before-unregister.txt" >&2
    exit 1
fi
if [[ ! -s "$temperature_smappservice_provider_unregister_fake/unregister-capture.md" ]]; then
    echo "Temperature SMAppService provider unregister capture missing summary" >&2
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

temperature_proof_ioreg_smc="$bag_mode_smoke_dir/temperature-proof-ioreg-smc"
cp -R "$temperature_proof_dir" "$temperature_proof_ioreg_smc"
sed -i '' 's/providerSource=powermetrics/providerSource=ioreg-smc/' "$temperature_proof_ioreg_smc/validation-config.txt"
sed -i '' 's/- Provider source: powermetrics/- Provider source: ioreg-smc/' "$temperature_proof_ioreg_smc/manual-result.md"
scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_ioreg_smc/provider-manifest.tsv" >/dev/null
temperature_proof_ioreg_pmu="$bag_mode_smoke_dir/temperature-proof-ioreg-pmu"
cp -R "$temperature_proof_dir" "$temperature_proof_ioreg_pmu"
sed -i '' 's/providerSource=powermetrics/providerSource=ioreg-pmu/' "$temperature_proof_ioreg_pmu/validation-config.txt"
sed -i '' 's/- Provider source: powermetrics/- Provider source: ioreg-pmu/' "$temperature_proof_ioreg_pmu/manual-result.md"
scripts/temperature-provider-proof-verify.sh --manifest "$temperature_proof_ioreg_pmu/provider-manifest.tsv" >/dev/null

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
if ! awk -F '\t' '
    function trim(value) {
        gsub(/\r/, "", value)
        sub(/^[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
        return value
    }
    function usable_note(value) {
        value = trim(value)
        return value != "" && value != "TODO" && value != "TBD" && !(value ~ /</ && value ~ />/) && value !~ / \| /
    }
    $1 == "combined-sensor-signal" && $2 == "n/a" && usable_note($4) { combined = 1 }
    $1 == "provider-update-or-restart" && $2 == "n/a" && usable_note($4) { restart = 1 }
    END { exit !(combined && restart) }
' "$temperature_proof_scaffold/provider-manifest.tsv"; then
    echo "Temperature provider proof scaffold missing optional n/a rows with notes" >&2
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
evidenceFormat=helper-prototype-v1
metadataRedacted=true
macOSVersion=15.0
appBundleIdentifier=com.example.ClawShell
helperLabel=com.example.ClawShell.Helper
launchDaemonPlist=ClawShell.app/Contents/Library/LaunchDaemons/com.example.ClawShell.Helper.plist
helperInstallPath=smappservice
localAuthModel=ad-hoc app/helper signature plus root-owned pairing token
developerIDApplicationSigned=false
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
- Helper install path: smappservice
- Helper install API/path: SMAppService.daemon(plistName:)

## Signing
- App signed: yes
- Helper signed: yes
- Local auth model recorded: yes
- Developer ID designated requirements recorded: N/A - no Apple Developer Program membership
- Package installer used: no
- Package signed with Developer ID Installer: N/A - no package installer used

## Lifecycle
- Install/status transition: requiresApproval -> enabled
- Admin approval/password flow confirmed: yes
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
    app-bundle-or-install-layout
    launchdaemon-plist
    app-signing-or-auth-model
    helper-signing-or-auth-model
    caller-auth-model
    fixed-command-api
    spctl-or-gatekeeper-assessment
    helper-install-or-register
    helper-status-after-approval
    admin-approval-or-password-flow
    helper-bootstrap-after-approval
    post-reboot-helper-bootstrap
    root-ledger-schema-and-permissions
    root-ledger-ownership-sample
    helper-update-old-inactive
    helper-update-ledger-compatibility
    helper-repair-conflict
    helper-uninstall
    helper-uninstall-state-cleanup
    cli-helper-status-repair-uninstall
    failure-unpaired-caller
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
    printf 'smappservice-rejection\tn/a\t\tSMAppService path used in this smoke\n'
    printf 'package-installer-signing\tn/a\t\tNo package installer used in this smoke\n'
    printf 'homebrew-cask-semantics\tn/a\t\tNo Homebrew cask used in this smoke\n'
} >"$helper_prototype_manifest"
scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_manifest" >/dev/null

helper_prototype_fallback_dir="$bag_mode_smoke_dir/helper-prototype-fallback"
cp -R "$helper_prototype_dir" "$helper_prototype_fallback_dir"
sed -i '' 's#launchDaemonPlist=ClawShell.app/Contents/Library/LaunchDaemons/com.example.ClawShell.Helper.plist#launchDaemonPlist=/Library/LaunchDaemons/com.example.ClawShell.Helper.plist#' "$helper_prototype_fallback_dir/validation-config.txt"
sed -i '' 's/helperInstallPath=smappservice/helperInstallPath=launchdaemon-fallback/' "$helper_prototype_fallback_dir/validation-config.txt"
sed -i '' 's#- LaunchDaemon plist: ClawShell.app/Contents/Library/LaunchDaemons/com.example.ClawShell.Helper.plist#- LaunchDaemon plist: /Library/LaunchDaemons/com.example.ClawShell.Helper.plist#' "$helper_prototype_fallback_dir/manual-result.md"
sed -i '' 's/- Helper install path: smappservice/- Helper install path: launchdaemon-fallback/' "$helper_prototype_fallback_dir/manual-result.md"
sed -i '' 's#- Helper install API/path: SMAppService.daemon(plistName:)#- Helper install API/path: launchctl bootstrap system /Library/LaunchDaemons/com.example.ClawShell.Helper.plist#' "$helper_prototype_fallback_dir/manual-result.md"
sed -i '' 's/- Install\/status transition: requiresApproval -> enabled/- Install\/status transition: bootout -> bootstrap -> running/' "$helper_prototype_fallback_dir/manual-result.md"
printf '$ smappservice-rejection\ncaptured kSMErrorInvalidSignature fallback evidence\n' >"$helper_prototype_fallback_dir/evidence/smappservice-rejection.txt"
sed -i '' 's#smappservice-rejection	n/a		SMAppService path used in this smoke#smappservice-rejection	evidence	evidence/smappservice-rejection.txt	fallback justified by SMAppService rejection#' "$helper_prototype_fallback_dir/prototype-manifest.tsv"
scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_fallback_dir/prototype-manifest.tsv" >/dev/null

helper_prototype_fallback_missing_rejection_dir="$bag_mode_smoke_dir/helper-prototype-fallback-missing-rejection"
cp -R "$helper_prototype_fallback_dir" "$helper_prototype_fallback_missing_rejection_dir"
sed -i '' 's#smappservice-rejection	evidence	evidence/smappservice-rejection.txt	fallback justified by SMAppService rejection#smappservice-rejection	n/a		No fallback rejection evidence#' "$helper_prototype_fallback_missing_rejection_dir/prototype-manifest.tsv"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_fallback_missing_rejection_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted fallback without SMAppService rejection evidence" >&2
    exit 1
fi
if ! grep -q "smappservice-rejection" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

helper_prototype_fallback_bad_plist_dir="$bag_mode_smoke_dir/helper-prototype-fallback-bad-plist"
cp -R "$helper_prototype_fallback_dir" "$helper_prototype_fallback_bad_plist_dir"
sed -i '' 's#launchDaemonPlist=/Library/LaunchDaemons/com.example.ClawShell.Helper.plist#launchDaemonPlist=ClawShell.app/Contents/Library/LaunchDaemons/com.example.ClawShell.Helper.plist#' "$helper_prototype_fallback_bad_plist_dir/validation-config.txt"
sed -i '' 's#- LaunchDaemon plist: /Library/LaunchDaemons/com.example.ClawShell.Helper.plist#- LaunchDaemon plist: ClawShell.app/Contents/Library/LaunchDaemons/com.example.ClawShell.Helper.plist#' "$helper_prototype_fallback_bad_plist_dir/manual-result.md"
if scripts/helper-service-prototype-verify.sh --manifest "$helper_prototype_fallback_bad_plist_dir/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted fallback without installed LaunchDaemon plist evidence" >&2
    exit 1
fi
if ! grep -q "/Library/LaunchDaemons" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi

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
if [[ "$(head -n 1 "$helper_prototype_scaffold/prototype-manifest.tsv")" != $'checkId\tstatus\tevidencePath\tnote' ]]; then
    echo "Helper service prototype scaffold wrote an unexpected manifest header" >&2
    cat "$helper_prototype_scaffold/prototype-manifest.tsv" >&2
    exit 1
fi
if ! awk -F '\t' 'NR == 1 { next } NF != 4 { exit 1 }' "$helper_prototype_scaffold/prototype-manifest.tsv"; then
    echo "Helper service prototype scaffold wrote a manifest row with an unexpected field count" >&2
    cat "$helper_prototype_scaffold/prototype-manifest.tsv" >&2
    exit 1
fi
helper_prototype_scaffold_expected_ids="$bag_mode_smoke_dir/helper-prototype-scaffold-expected-ids"
helper_prototype_scaffold_actual_ids="$bag_mode_smoke_dir/helper-prototype-scaffold-actual-ids"
{
    for check_id in "${helper_prototype_required_checks[@]}"; do
        printf '%s\n' "$check_id"
    done
    printf '%s\n' "smappservice-rejection"
    printf '%s\n' "package-installer-signing"
    printf '%s\n' "homebrew-cask-semantics"
} | sort >"$helper_prototype_scaffold_expected_ids"
tail -n +2 "$helper_prototype_scaffold/prototype-manifest.tsv" | awk -F '\t' '{ print $1 }' | sort >"$helper_prototype_scaffold_actual_ids"
if ! diff -u "$helper_prototype_scaffold_expected_ids" "$helper_prototype_scaffold_actual_ids" >"$bag_mode_smoke_error"; then
    echo "Helper service prototype scaffold wrote an unexpected manifest row set" >&2
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
for check_id in "${helper_prototype_required_checks[@]}"; do
    if ! awk -F '\t' -v check_id="$check_id" '$1 == check_id && $2 == "TODO" { found = 1 } END { exit !found }' "$helper_prototype_scaffold/prototype-manifest.tsv"; then
        echo "Helper service prototype scaffold missing required TODO row: $check_id" >&2
        cat "$helper_prototype_scaffold/prototype-manifest.tsv" >&2
        exit 1
    fi
done
if ! awk -F '\t' '
    function trim(value) {
        gsub(/\r/, "", value)
        sub(/^[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
        return value
    }
    function usable_note(value) {
        value = trim(value)
        return value != "" && value != "TODO" && value != "TBD" && !(value ~ /</ && value ~ />/) && value !~ / \| /
    }
    $1 == "smappservice-rejection" && $2 == "n/a" && usable_note($4) { rejection = 1 }
    $1 == "package-installer-signing" && $2 == "n/a" && usable_note($4) { package = 1 }
    $1 == "homebrew-cask-semantics" && $2 == "n/a" && usable_note($4) { cask = 1 }
    END { exit !(rejection && package && cask) }
' "$helper_prototype_scaffold/prototype-manifest.tsv"; then
    echo "Helper service prototype scaffold missing optional n/a rows with notes" >&2
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

helper_smappservice_prepare="$bag_mode_smoke_dir/helper-smappservice-prepare-&-xml"
scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_prepare" >/dev/null
for required_file in validation-config.txt manual-result.md prototype-manifest.tsv README.md; do
    if [[ ! -f "$helper_smappservice_prepare/$required_file" ]]; then
        echo "SMAppService helper prototype harness did not write expected file: $required_file" >&2
        exit 1
    fi
done
if [[ ! -x "$helper_smappservice_prepare/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototype" ]]; then
    echo "SMAppService helper prototype harness did not build controller executable" >&2
    exit 1
fi
if [[ ! -x "$helper_smappservice_prepare/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototypeDaemon" ]]; then
    echo "SMAppService helper prototype harness did not build helper executable" >&2
    exit 1
fi
if ! grep -q '^helperInstallPath=smappservice$' "$helper_smappservice_prepare/validation-config.txt"; then
    echo "SMAppService helper prototype harness did not record smappservice path" >&2
    exit 1
fi
helper_smappservice_prepare_identity="$(awk -F= '$1 == "identitySuffix" { print $2; found = 1 } END { exit !found }' "$helper_smappservice_prepare/validation-config.txt")"
helper_smappservice_prepare_label="$(awk -F= '$1 == "helperLabel" { print $2; found = 1 } END { exit !found }' "$helper_smappservice_prepare/validation-config.txt")"
rebase_helper_smappservice_launchdaemon() {
    local artifact_dir="$1"
    local artifact_plist="$artifact_dir/ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons/$helper_smappservice_prepare_label.plist"
    if [[ ! -f "$artifact_plist" ]]; then
        return 0
    fi
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $artifact_dir/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototypeDaemon" "$artifact_plist"
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:5 $artifact_dir/runtime/helper.log" "$artifact_plist"
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:7 $artifact_dir/runtime/helper-ledger.jsonl" "$artifact_plist"
    /usr/libexec/PlistBuddy -c "Set :StandardOutPath $artifact_dir/runtime/helper.stdout.log" "$artifact_plist"
    /usr/libexec/PlistBuddy -c "Set :StandardErrorPath $artifact_dir/runtime/helper.stderr.log" "$artifact_plist"
}
if [[ ! "$helper_smappservice_prepare_identity" =~ ^h[A-Fa-f0-9]{10}$ ]]; then
    echo "SMAppService helper prototype harness did not derive a stable unique identity suffix" >&2
    cat "$helper_smappservice_prepare/validation-config.txt" >&2
    exit 1
fi
if [[ "$helper_smappservice_prepare_label" != "com.makeavish.ClawShell.HelperPrototype.$helper_smappservice_prepare_identity.daemon" ]]; then
    echo "SMAppService helper prototype harness did not record derived helper label" >&2
    cat "$helper_smappservice_prepare/validation-config.txt" >&2
    exit 1
fi
if ! grep -q "^appBundleIdentifier=com.makeavish.ClawShell.HelperPrototype.$helper_smappservice_prepare_identity$" "$helper_smappservice_prepare/validation-config.txt"; then
    echo "SMAppService helper prototype harness did not record derived app bundle id" >&2
    cat "$helper_smappservice_prepare/validation-config.txt" >&2
    exit 1
fi
if ! plutil -extract Label raw -o - "$helper_smappservice_prepare/ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons/$helper_smappservice_prepare_label.plist" | grep -qx "$helper_smappservice_prepare_label"; then
    echo "SMAppService helper prototype LaunchDaemon label does not match helper label" >&2
    cat "$helper_smappservice_prepare/validation-config.txt" >&2
    exit 1
fi
if ! grep -q "plistName=$helper_smappservice_prepare_label.plist" "$helper_smappservice_prepare/evidence/helper-status-before-approval.txt"; then
    echo "SMAppService helper prototype controller did not use the derived plist name" >&2
    cat "$helper_smappservice_prepare/evidence/helper-status-before-approval.txt" >&2
    exit 1
fi
if ! grep -q '^daemonCommand=status$' "$helper_smappservice_prepare/validation-config.txt"; then
    echo "SMAppService helper prototype harness did not record default daemon command" >&2
    cat "$helper_smappservice_prepare/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^helperGeneration=1$' "$helper_smappservice_prepare/validation-config.txt"; then
    echo "SMAppService helper prototype harness did not record default helper generation" >&2
    cat "$helper_smappservice_prepare/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^rootLedgerPath=runtime/helper-ledger.jsonl$' "$helper_smappservice_prepare/validation-config.txt"; then
    echo "SMAppService helper prototype harness did not record root ledger path" >&2
    cat "$helper_smappservice_prepare/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '2 => "--command"' "$helper_smappservice_prepare/evidence/launchdaemon-plist.txt" ||
    ! grep -q '3 => "status"' "$helper_smappservice_prepare/evidence/launchdaemon-plist.txt" ||
    ! grep -q '6 => "--ledger"' "$helper_smappservice_prepare/evidence/launchdaemon-plist.txt" ||
    ! grep -q '7 => ".*runtime/helper-ledger.jsonl"' "$helper_smappservice_prepare/evidence/launchdaemon-plist.txt"; then
    echo "SMAppService helper prototype LaunchDaemon did not include default command argument" >&2
    cat "$helper_smappservice_prepare/evidence/launchdaemon-plist.txt" >&2
    exit 1
fi
if ! grep -q '^registerAttempted=false$' "$helper_smappservice_prepare/validation-config.txt"; then
    echo "SMAppService helper prototype harness unexpectedly attempted registration in default mode" >&2
    exit 1
fi
for required_status in \
    app-bundle-or-install-layout \
    launchdaemon-plist \
    app-signing-or-auth-model \
    helper-signing-or-auth-model \
    caller-auth-model \
    fixed-command-api \
    failure-unpaired-caller \
    failure-wrong-bundle-id-or-label \
    failure-wrong-user \
    failure-stale-app-version \
    failure-denied-or-revoked-approval \
    helper-status-before-approval
do
    if ! grep -q '^exitCode=0$' "$helper_smappservice_prepare/evidence/$required_status.status"; then
        echo "SMAppService helper prototype required capture failed: $required_status" >&2
        cat "$helper_smappservice_prepare/evidence/$required_status.status" >&2
        cat "$helper_smappservice_prepare/evidence/$required_status.txt" >&2
        exit 1
    fi
done
if ! awk -F '\t' '$1 == "helper-install-or-register" && $2 == "TODO" { found = 1 } END { exit !found }' "$helper_smappservice_prepare/prototype-manifest.tsv"; then
    echo "SMAppService helper prototype harness should leave register row as TODO in default mode" >&2
    cat "$helper_smappservice_prepare/prototype-manifest.tsv" >&2
    exit 1
fi
if ! awk -F '\t' '$1 == "fixed-command-api" && $2 == "TODO" && $4 ~ /Dry-run command parser smoke/ { found = 1 } END { exit !found }' "$helper_smappservice_prepare/prototype-manifest.tsv"; then
    echo "SMAppService helper prototype harness should leave fixed command API row as TODO until approved helper evidence exists" >&2
    cat "$helper_smappservice_prepare/prototype-manifest.tsv" >&2
    exit 1
fi
for failure_row in \
    failure-unpaired-caller \
    failure-wrong-bundle-id-or-label \
    failure-wrong-user \
    failure-stale-app-version \
    failure-denied-or-revoked-approval
do
    if ! awk -F '\t' -v row="$failure_row" '$1 == row && $2 == "evidence" && $3 == "evidence/" row ".txt" { found = 1 } END { exit !found }' "$helper_smappservice_prepare/prototype-manifest.tsv"; then
        echo "SMAppService helper prototype harness did not promote failure row evidence: $failure_row" >&2
        cat "$helper_smappservice_prepare/prototype-manifest.tsv" >&2
        exit 1
    fi
done
if ! grep -q 'pairing-token' "$helper_smappservice_prepare/validation-config.txt"; then
    echo "SMAppService helper prototype validation config did not describe local auth failure model" >&2
    cat "$helper_smappservice_prepare/validation-config.txt" >&2
    exit 1
fi
for allowed_command in status enableBagMode disableBagMode repair uninstall; do
    if ! grep -Fq "commandJson=\"$allowed_command\"" "$helper_smappservice_prepare/evidence/fixed-command-api.txt"; then
        echo "SMAppService helper prototype fixed command API evidence missing allowed command: $allowed_command" >&2
        cat "$helper_smappservice_prepare/evidence/fixed-command-api.txt" >&2
        exit 1
    fi
    if ! grep -Fq "observedExitCode[$allowed_command]=0" "$helper_smappservice_prepare/evidence/fixed-command-api.txt"; then
        echo "SMAppService helper prototype fixed command API did not accept allowed command: $allowed_command" >&2
        cat "$helper_smappservice_prepare/evidence/fixed-command-api.txt" >&2
        exit 1
    fi
done
if ! grep -Fq 'commandJson="arbitraryShellCommand"' "$helper_smappservice_prepare/evidence/fixed-command-api.txt"; then
    echo "SMAppService helper prototype fixed command API evidence missing rejected command" >&2
    cat "$helper_smappservice_prepare/evidence/fixed-command-api.txt" >&2
    exit 1
fi
if ! grep -Fq 'allowed=false' "$helper_smappservice_prepare/evidence/fixed-command-api.txt"; then
    echo "SMAppService helper prototype fixed command API did not mark arbitrary command as rejected" >&2
    cat "$helper_smappservice_prepare/evidence/fixed-command-api.txt" >&2
    exit 1
fi
if ! grep -Fq 'observedExitCode[arbitraryShellCommand]=64' "$helper_smappservice_prepare/evidence/fixed-command-api.txt"; then
    echo "SMAppService helper prototype fixed command API did not reject arbitrary command with exit 64" >&2
    cat "$helper_smappservice_prepare/evidence/fixed-command-api.txt" >&2
    exit 1
fi
if ! grep -Fq 'helperGeneration=1' "$helper_smappservice_prepare/evidence/fixed-command-api.txt" ||
    ! grep -Fq '"helperGeneration":1' "$helper_smappservice_prepare/evidence/fixed-command-api.txt"; then
    echo "SMAppService helper prototype fixed command API did not emit default helper generation" >&2
    cat "$helper_smappservice_prepare/evidence/fixed-command-api.txt" >&2
    exit 1
fi
check_helper_failure_case() {
    local failure_case="$1"
    local expected_marker="$2"
    if ! grep -q "$expected_marker" "$helper_smappservice_prepare/evidence/$failure_case.txt"; then
        echo "SMAppService helper prototype missing auth failure marker for $failure_case" >&2
        cat "$helper_smappservice_prepare/evidence/$failure_case.txt" >&2
        exit 1
    fi
    if ! grep -q '^observedExitCode=77$' "$helper_smappservice_prepare/evidence/$failure_case.txt"; then
        echo "SMAppService helper prototype did not reject $failure_case with exit 77" >&2
        cat "$helper_smappservice_prepare/evidence/$failure_case.txt" >&2
        exit 1
    fi
}
check_helper_failure_case failure-unpaired-caller unpaired-caller
check_helper_failure_case failure-wrong-bundle-id-or-label wrong-bundle-id
check_helper_failure_case failure-wrong-user wrong-user
check_helper_failure_case failure-stale-app-version stale-app-version
if ! grep -q "wrong-helper-label" "$helper_smappservice_prepare/evidence/failure-wrong-bundle-id-or-label.txt"; then
    echo "SMAppService helper prototype wrong bundle/label case did not record label mismatch" >&2
    cat "$helper_smappservice_prepare/evidence/failure-wrong-bundle-id-or-label.txt" >&2
    exit 1
fi
if ! grep -q "approval-denied" "$helper_smappservice_prepare/evidence/failure-denied-or-revoked-approval.txt" ||
    ! grep -q "approval-revoked" "$helper_smappservice_prepare/evidence/failure-denied-or-revoked-approval.txt"; then
    echo "SMAppService helper prototype did not record denied and revoked approval failures" >&2
    cat "$helper_smappservice_prepare/evidence/failure-denied-or-revoked-approval.txt" >&2
    exit 1
fi
if scripts/helper-service-prototype-verify.sh --manifest "$helper_smappservice_prepare/prototype-manifest.tsv" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "Helper service prototype verifier accepted incomplete SMAppService prepare artifact" >&2
    exit 1
fi
if ! grep -q "helper-install-or-register" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if ! grep -q "fixed-command-api" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_manual_identity="$bag_mode_smoke_dir/helper-smappservice-manual-identity"
CLAWSHELL_HELPER_PROTOTYPE_ID_SUFFIX=manual01 \
    scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_manual_identity" >/dev/null
if ! grep -q '^identitySuffix=manual01$' "$helper_smappservice_manual_identity/validation-config.txt"; then
    echo "SMAppService helper prototype harness did not honor manual identity suffix" >&2
    cat "$helper_smappservice_manual_identity/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^helperLabel=com.makeavish.ClawShell.HelperPrototype.manual01.daemon$' "$helper_smappservice_manual_identity/validation-config.txt"; then
    echo "SMAppService helper prototype harness did not use manual helper label" >&2
    cat "$helper_smappservice_manual_identity/validation-config.txt" >&2
    exit 1
fi
if ! grep -q 'plistName=com.makeavish.ClawShell.HelperPrototype.manual01.daemon.plist' "$helper_smappservice_manual_identity/evidence/helper-status-before-approval.txt"; then
    echo "SMAppService helper prototype controller did not use manual plist name" >&2
    cat "$helper_smappservice_manual_identity/evidence/helper-status-before-approval.txt" >&2
    exit 1
fi
helper_smappservice_daemon_command="$bag_mode_smoke_dir/helper-smappservice-daemon-command"
CLAWSHELL_HELPER_PROTOTYPE_DAEMON_COMMAND=repair \
    scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_daemon_command" >/dev/null
if ! grep -q '^daemonCommand=repair$' "$helper_smappservice_daemon_command/validation-config.txt"; then
    echo "SMAppService helper prototype harness did not honor daemon command" >&2
    cat "$helper_smappservice_daemon_command/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '3 => "repair"' "$helper_smappservice_daemon_command/evidence/launchdaemon-plist.txt"; then
    echo "SMAppService helper prototype LaunchDaemon did not include configured daemon command" >&2
    cat "$helper_smappservice_daemon_command/evidence/launchdaemon-plist.txt" >&2
    exit 1
fi
helper_smappservice_generation="$bag_mode_smoke_dir/helper-smappservice-generation"
CLAWSHELL_HELPER_PROTOTYPE_GENERATION=7 \
    scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_generation" >/dev/null
if ! grep -q '^helperGeneration=7$' "$helper_smappservice_generation/validation-config.txt"; then
    echo "SMAppService helper prototype harness did not honor helper generation" >&2
    cat "$helper_smappservice_generation/validation-config.txt" >&2
    exit 1
fi
if ! grep -Fq 'helperGeneration=7' "$helper_smappservice_generation/evidence/fixed-command-api.txt" ||
    ! grep -Fq '"helperGeneration":7' "$helper_smappservice_generation/evidence/fixed-command-api.txt"; then
    echo "SMAppService helper prototype command evidence did not emit configured helper generation" >&2
    cat "$helper_smappservice_generation/evidence/fixed-command-api.txt" >&2
    exit 1
fi
helper_smappservice_bad_generation="$bag_mode_smoke_dir/helper-smappservice-bad-generation"
if CLAWSHELL_HELPER_PROTOTYPE_GENERATION=0 \
    scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_bad_generation" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness accepted an invalid helper generation" >&2
    exit 1
fi
if ! grep -q "CLAWSHELL_HELPER_PROTOTYPE_GENERATION must be a positive integer" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_huge_generation="$bag_mode_smoke_dir/helper-smappservice-huge-generation"
if CLAWSHELL_HELPER_PROTOTYPE_GENERATION=999999999999999999999999999999999999999999999999 \
    scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_huge_generation" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness accepted an out-of-range helper generation" >&2
    exit 1
fi
if ! grep -q "CLAWSHELL_HELPER_PROTOTYPE_GENERATION must be a positive integer no greater than 2147483647" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_bad_daemon_command="$bag_mode_smoke_dir/helper-smappservice-bad-daemon-command"
if CLAWSHELL_HELPER_PROTOTYPE_DAEMON_COMMAND=arbitraryShellCommand \
    scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_bad_daemon_command" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness accepted an invalid daemon command" >&2
    exit 1
fi
if ! grep -q "CLAWSHELL_HELPER_PROTOTYPE_DAEMON_COMMAND must be one of" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_bad_identity="$bag_mode_smoke_dir/helper-smappservice-bad-identity"
if CLAWSHELL_HELPER_PROTOTYPE_ID_SUFFIX=bad-suffix \
    scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_bad_identity" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness accepted an invalid identity suffix" >&2
    exit 1
fi
if ! grep -q "CLAWSHELL_HELPER_PROTOTYPE_ID_SUFFIX must start with a letter" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_register_without_ack="$bag_mode_smoke_dir/helper-smappservice-register-without-ack"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_register_without_ack" --register >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness allowed register without acknowledgement" >&2
    exit 1
fi
if ! grep -q -- "--i-understand-this-registers-helper" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_missing="$bag_mode_smoke_dir/helper-smappservice-capture-missing"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_missing" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness allowed post-approval capture without an existing artifact" >&2
    exit 1
fi
if ! grep -q "existing artifact directory" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_malformed="$bag_mode_smoke_dir/helper-smappservice-capture-malformed"
mkdir -p "$helper_smappservice_capture_malformed"
printf 'not a helper artifact\n' >"$helper_smappservice_capture_malformed/junk.txt"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_malformed" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness allowed post-approval capture on malformed artifact" >&2
    exit 1
fi
if ! grep -q "missing required artifact file path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
for unexpected_path in \
    "$helper_smappservice_capture_malformed/ClawShellHelperPrototype.app" \
    "$helper_smappservice_capture_malformed/evidence" \
    "$helper_smappservice_capture_malformed/runtime" \
    "$helper_smappservice_capture_malformed/source-package"
do
    if [[ -e "$unexpected_path" ]]; then
        echo "SMAppService helper prototype post-approval capture mutated malformed artifact: $unexpected_path" >&2
        exit 1
    fi
done
helper_smappservice_capture_symlink_executable="$bag_mode_smoke_dir/helper-smappservice-capture-symlink-executable"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_symlink_executable"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_symlink_executable"
rm -f "$helper_smappservice_capture_symlink_executable/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototype"
ln -s /bin/echo "$helper_smappservice_capture_symlink_executable/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototype"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_symlink_executable" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype post-approval capture ran a symlinked controller path" >&2
    exit 1
fi
if ! grep -q "regular executable artifact path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_symlink_plist="$bag_mode_smoke_dir/helper-smappservice-capture-symlink-plist"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_symlink_plist"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_symlink_plist"
rm -f "$helper_smappservice_capture_symlink_plist/ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons/$helper_smappservice_prepare_label.plist"
ln -s /etc/hosts "$helper_smappservice_capture_symlink_plist/ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons/$helper_smappservice_prepare_label.plist"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_symlink_plist" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype post-approval capture accepted a symlinked LaunchDaemon plist" >&2
    exit 1
fi
if ! grep -q "regular bundle metadata path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_mismatched_label="$bag_mode_smoke_dir/helper-smappservice-capture-mismatched-label"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_mismatched_label"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_mismatched_label"
sed -i '' 's/^helperLabel=.*/helperLabel=com.makeavish.ClawShell.HelperPrototype.other.daemon/' "$helper_smappservice_capture_mismatched_label/validation-config.txt"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_mismatched_label" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype post-approval capture accepted helperLabel mismatched with identitySuffix" >&2
    exit 1
fi
if ! grep -q "helperLabel to match identitySuffix" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_mismatched_bundle="$bag_mode_smoke_dir/helper-smappservice-capture-mismatched-bundle"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_mismatched_bundle"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_mismatched_bundle"
sed -i '' 's/^appBundleIdentifier=.*/appBundleIdentifier=com.makeavish.ClawShell.HelperPrototype.other/' "$helper_smappservice_capture_mismatched_bundle/validation-config.txt"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_mismatched_bundle" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype post-approval capture accepted appBundleIdentifier mismatched with identitySuffix" >&2
    exit 1
fi
if ! grep -q "appBundleIdentifier to match identitySuffix" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_missing_command="$bag_mode_smoke_dir/helper-smappservice-capture-missing-command"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_missing_command"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_missing_command"
sed -i '' '/^daemonCommand=/d' "$helper_smappservice_capture_missing_command/validation-config.txt"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_missing_command" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype post-approval capture accepted missing daemonCommand" >&2
    exit 1
fi
if ! grep -q "missing required daemonCommand" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_mismatched_command="$bag_mode_smoke_dir/helper-smappservice-capture-mismatched-command"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_mismatched_command"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_mismatched_command"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:3 repair" "$helper_smappservice_capture_mismatched_command/ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons/$helper_smappservice_prepare_label.plist"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_mismatched_command" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype post-approval capture accepted LaunchDaemon command mismatched with daemonCommand" >&2
    exit 1
fi
if ! grep -q "LaunchDaemon ProgramArguments to match daemonCommand" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
for tampered_arg_case in \
    "0|/bin/echo|LaunchDaemon ProgramArguments to use the bundled helper daemon" \
    "1|--not-daemon|LaunchDaemon ProgramArguments to use the bundled helper daemon" \
    "2|--not-command|LaunchDaemon ProgramArguments to match daemonCommand" \
    "4|--not-log|LaunchDaemon ProgramArguments to use the artifact helper log" \
    "5|$bag_mode_smoke_dir/outside-helper.log|LaunchDaemon ProgramArguments to use the artifact helper log" \
    "6|--not-ledger|LaunchDaemon ProgramArguments to match rootLedgerPath"
do
    IFS='|' read -r tampered_arg_index tampered_arg_value tampered_arg_error <<EOF
$tampered_arg_case
EOF
    helper_smappservice_capture_tampered_arg="$bag_mode_smoke_dir/helper-smappservice-capture-tampered-arg-$tampered_arg_index"
    cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_tampered_arg"
    rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_tampered_arg"
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:$tampered_arg_index $tampered_arg_value" "$helper_smappservice_capture_tampered_arg/ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons/$helper_smappservice_prepare_label.plist"
    if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_tampered_arg" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
        echo "SMAppService helper prototype post-approval capture accepted tampered ProgramArguments.$tampered_arg_index" >&2
        exit 1
    fi
    if ! grep -q "$tampered_arg_error" "$bag_mode_smoke_error"; then
        cat "$bag_mode_smoke_error" >&2
        exit 1
    fi
done
helper_smappservice_capture_extra_arg="$bag_mode_smoke_dir/helper-smappservice-capture-extra-arg"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_extra_arg"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_extra_arg"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:8 string unexpected" "$helper_smappservice_capture_extra_arg/ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons/$helper_smappservice_prepare_label.plist"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_extra_arg" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype post-approval capture accepted extra LaunchDaemon argument" >&2
    exit 1
fi
if ! grep -q "LaunchDaemon ProgramArguments to contain only the expected helper arguments" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
for tampered_stream_case in \
    "StandardOutPath|$bag_mode_smoke_dir/outside-helper.stdout.log|LaunchDaemon StandardOutPath to use the artifact helper stdout log" \
    "StandardErrorPath|$bag_mode_smoke_dir/outside-helper.stderr.log|LaunchDaemon StandardErrorPath to use the artifact helper stderr log"
do
    IFS='|' read -r tampered_stream_key tampered_stream_value tampered_stream_error <<EOF
$tampered_stream_case
EOF
    helper_smappservice_capture_tampered_stream="$bag_mode_smoke_dir/helper-smappservice-capture-tampered-$tampered_stream_key"
    cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_tampered_stream"
    rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_tampered_stream"
    /usr/libexec/PlistBuddy -c "Set :$tampered_stream_key $tampered_stream_value" "$helper_smappservice_capture_tampered_stream/ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons/$helper_smappservice_prepare_label.plist"
    if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_tampered_stream" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
        echo "SMAppService helper prototype post-approval capture accepted tampered $tampered_stream_key" >&2
        exit 1
    fi
    if ! grep -q "$tampered_stream_error" "$bag_mode_smoke_error"; then
        cat "$bag_mode_smoke_error" >&2
        exit 1
    fi
done
helper_smappservice_capture_missing_ledger="$bag_mode_smoke_dir/helper-smappservice-capture-missing-ledger"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_missing_ledger"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_missing_ledger"
sed -i '' '/^rootLedgerPath=/d' "$helper_smappservice_capture_missing_ledger/validation-config.txt"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_missing_ledger" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype post-approval capture accepted missing rootLedgerPath" >&2
    exit 1
fi
if ! grep -q "missing required rootLedgerPath" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_bad_ledger_config="$bag_mode_smoke_dir/helper-smappservice-capture-bad-ledger-config"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_bad_ledger_config"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_bad_ledger_config"
sed -i '' 's#^rootLedgerPath=.*#rootLedgerPath=runtime/other-ledger.jsonl#' "$helper_smappservice_capture_bad_ledger_config/validation-config.txt"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_bad_ledger_config" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype post-approval capture accepted unsupported rootLedgerPath" >&2
    exit 1
fi
if ! grep -q "requires rootLedgerPath to be runtime/helper-ledger.jsonl" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_mismatched_ledger="$bag_mode_smoke_dir/helper-smappservice-capture-mismatched-ledger"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_mismatched_ledger"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_mismatched_ledger"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:7 $helper_smappservice_capture_mismatched_ledger/runtime/other-ledger.jsonl" "$helper_smappservice_capture_mismatched_ledger/ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons/$helper_smappservice_prepare_label.plist"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_mismatched_ledger" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype post-approval capture accepted LaunchDaemon ledger mismatched with rootLedgerPath" >&2
    exit 1
fi
if ! grep -q "LaunchDaemon ProgramArguments to match rootLedgerPath" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_symlink_config="$bag_mode_smoke_dir/helper-smappservice-capture-symlink-config"
helper_smappservice_capture_config_victim="$bag_mode_smoke_dir/helper-smappservice-capture-config-victim"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_symlink_config"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_symlink_config"
printf 'victim-before\n' >"$helper_smappservice_capture_config_victim"
rm -f "$helper_smappservice_capture_symlink_config/validation-config.txt"
ln -s "$helper_smappservice_capture_config_victim" "$helper_smappservice_capture_symlink_config/validation-config.txt"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_symlink_config" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype post-approval capture accepted a symlinked validation config" >&2
    exit 1
fi
if ! grep -q "regular artifact file path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if [[ "$(cat "$helper_smappservice_capture_config_victim")" != "victim-before" ]]; then
    echo "SMAppService helper prototype post-approval capture followed validation-config symlink" >&2
    cat "$helper_smappservice_capture_config_victim" >&2
    exit 1
fi
helper_smappservice_capture_non_regular_manifest="$bag_mode_smoke_dir/helper-smappservice-capture-non-regular-manifest"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_non_regular_manifest"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_non_regular_manifest"
rm -f "$helper_smappservice_capture_non_regular_manifest/prototype-manifest.tsv"
mkdir "$helper_smappservice_capture_non_regular_manifest/prototype-manifest.tsv"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_non_regular_manifest" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype post-approval capture accepted a non-regular prototype manifest" >&2
    exit 1
fi
if ! grep -q "regular artifact file path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_bad_evidence="$bag_mode_smoke_dir/helper-smappservice-capture-bad-evidence"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_bad_evidence"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_bad_evidence"
rm -rf "$helper_smappservice_capture_bad_evidence/evidence"
printf 'not an evidence directory\n' >"$helper_smappservice_capture_bad_evidence/evidence"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_bad_evidence" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness allowed post-approval capture with evidence path as a file" >&2
    exit 1
fi
if ! grep -q "required artifact directory path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if grep -q '^postApprovalCaptureAttempted=true$' "$helper_smappservice_capture_bad_evidence/validation-config.txt"; then
    echo "SMAppService helper prototype post-approval capture mutated config after malformed evidence path" >&2
    cat "$helper_smappservice_capture_bad_evidence/validation-config.txt" >&2
    exit 1
fi
helper_smappservice_capture_symlink_evidence="$bag_mode_smoke_dir/helper-smappservice-capture-symlink-evidence"
helper_smappservice_capture_symlink_target="$bag_mode_smoke_dir/helper-smappservice-capture-symlink-target"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_symlink_evidence"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_symlink_evidence"
mkdir -p "$helper_smappservice_capture_symlink_target"
rm -rf "$helper_smappservice_capture_symlink_evidence/evidence"
ln -s "$helper_smappservice_capture_symlink_target" "$helper_smappservice_capture_symlink_evidence/evidence"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_symlink_evidence" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness allowed post-approval capture with symlinked evidence directory" >&2
    exit 1
fi
if ! grep -q "not a symlink" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if find "$helper_smappservice_capture_symlink_target" -mindepth 1 -print -quit | grep -q .; then
    echo "SMAppService helper prototype post-approval capture wrote through symlinked evidence directory" >&2
    find "$helper_smappservice_capture_symlink_target" -mindepth 1 -maxdepth 2 -print >&2
    exit 1
fi
if grep -q '^postApprovalCaptureAttempted=true$' "$helper_smappservice_capture_symlink_evidence/validation-config.txt"; then
    echo "SMAppService helper prototype post-approval capture mutated config after symlinked evidence path" >&2
    cat "$helper_smappservice_capture_symlink_evidence/validation-config.txt" >&2
    exit 1
fi
helper_smappservice_capture_unwritable="$bag_mode_smoke_dir/helper-smappservice-capture-unwritable"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_unwritable"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_unwritable"
chmod a-w "$helper_smappservice_capture_unwritable/evidence"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_unwritable" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    chmod u+w "$helper_smappservice_capture_unwritable/evidence"
    echo "SMAppService helper prototype harness allowed post-approval capture with unwritable evidence directory" >&2
    exit 1
fi
chmod u+w "$helper_smappservice_capture_unwritable/evidence"
if ! grep -q "requires writable artifact directory path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if grep -q '^postApprovalCaptureAttempted=true$' "$helper_smappservice_capture_unwritable/validation-config.txt"; then
    echo "SMAppService helper prototype post-approval capture mutated config after unwritable evidence path" >&2
    cat "$helper_smappservice_capture_unwritable/validation-config.txt" >&2
    exit 1
fi
helper_smappservice_capture_readonly_file="$bag_mode_smoke_dir/helper-smappservice-capture-readonly-file"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_readonly_file"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_readonly_file"
touch "$helper_smappservice_capture_readonly_file/evidence/helper-status-after-approval.txt"
touch "$helper_smappservice_capture_readonly_file/evidence/helper-status-after-approval.status"
chmod a-w "$helper_smappservice_capture_readonly_file/evidence/helper-status-after-approval.txt" \
    "$helper_smappservice_capture_readonly_file/evidence/helper-status-after-approval.status"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_readonly_file" --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    chmod u+w "$helper_smappservice_capture_readonly_file/evidence/helper-status-after-approval.txt" \
        "$helper_smappservice_capture_readonly_file/evidence/helper-status-after-approval.status"
    echo "SMAppService helper prototype harness allowed post-approval capture with read-only capture files" >&2
    exit 1
fi
chmod u+w "$helper_smappservice_capture_readonly_file/evidence/helper-status-after-approval.txt" \
    "$helper_smappservice_capture_readonly_file/evidence/helper-status-after-approval.status"
if ! grep -q "requires writable capture path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if grep -q '^postApprovalCaptureAttempted=true$' "$helper_smappservice_capture_readonly_file/validation-config.txt"; then
    echo "SMAppService helper prototype post-approval capture mutated config after read-only capture files" >&2
    cat "$helper_smappservice_capture_readonly_file/validation-config.txt" >&2
    exit 1
fi
helper_smappservice_capture_temp_symlink="$bag_mode_smoke_dir/helper-smappservice-capture-temp-symlink"
helper_smappservice_capture_temp_victim="$bag_mode_smoke_dir/helper-smappservice-capture-temp-victim"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_temp_symlink"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_temp_symlink"
printf 'victim-before\n' >"$helper_smappservice_capture_temp_victim"
ln -s "$helper_smappservice_capture_temp_victim" "$helper_smappservice_capture_temp_symlink/validation-config.txt.tmp"
CLAWSHELL_SMAPP_LOG_LAST=1m scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_temp_symlink" --capture-post-approval >/dev/null
if [[ "$(cat "$helper_smappservice_capture_temp_victim")" != "victim-before" ]]; then
    echo "SMAppService helper prototype post-approval capture followed validation-config temp symlink" >&2
    cat "$helper_smappservice_capture_temp_victim" >&2
    exit 1
fi
if [[ -L "$helper_smappservice_capture_temp_symlink/validation-config.txt" ]]; then
    echo "SMAppService helper prototype post-approval capture replaced validation-config with a symlink" >&2
    exit 1
fi
if ! grep -q '^postApprovalCaptureAttempted=true$' "$helper_smappservice_capture_temp_symlink/validation-config.txt"; then
    echo "SMAppService helper prototype post-approval capture did not update config with temp symlink present" >&2
    cat "$helper_smappservice_capture_temp_symlink/validation-config.txt" >&2
    exit 1
fi
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_prepare" --capture-post-approval --register --i-understand-this-registers-helper >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness allowed post-approval capture combined with register" >&2
    exit 1
fi
if ! grep -q "Use only one" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_prepare" --capture-post-reboot --capture-post-approval >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness allowed post-reboot capture combined with post-approval capture" >&2
    exit 1
fi
if ! grep -q "Use only one" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
CLAWSHELL_SMAPP_LOG_LAST=1m scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_prepare" --capture-post-approval >/dev/null
if ! grep -q '^postApprovalCaptureAttempted=true$' "$helper_smappservice_prepare/validation-config.txt"; then
    echo "SMAppService helper prototype post-approval capture did not update validation config" >&2
    cat "$helper_smappservice_prepare/validation-config.txt" >&2
    exit 1
fi
if ! grep -q "missingOrEmpty=.*runtime/helper-ledger.jsonl" "$helper_smappservice_prepare/evidence/root-ledger-schema-and-permissions.txt"; then
    echo "SMAppService helper prototype unapproved post-approval capture did not mark missing ledger explicitly" >&2
    cat "$helper_smappservice_prepare/evidence/root-ledger-schema-and-permissions.txt" >&2
    exit 1
fi
if ! grep -q '^exitCode=1$' "$helper_smappservice_prepare/evidence/root-ledger-schema-and-permissions.status"; then
    echo "SMAppService helper prototype unapproved post-approval capture did not record missing ledger as non-zero evidence status" >&2
    cat "$helper_smappservice_prepare/evidence/root-ledger-schema-and-permissions.status" >&2
    exit 1
fi
printf '%s\n' \
    'event=helper-command' \
    'commandJson="status"' \
    '{"schemaVersion":1,"event":"bagModeHelperLedgerSample","command":"status","effect":"dry-run"}' \
    >"$helper_smappservice_prepare/runtime/helper.stdout.log"
CLAWSHELL_SMAPP_LOG_LAST=1m scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_prepare" --capture-post-approval >/dev/null
if ! grep -q '^exitCode=0$' "$helper_smappservice_prepare/evidence/helper-stdout-after-approval.status"; then
    echo "SMAppService helper prototype post-approval stdout capture did not succeed for seeded stdout" >&2
    cat "$helper_smappservice_prepare/evidence/helper-stdout-after-approval.status" >&2
    cat "$helper_smappservice_prepare/evidence/helper-stdout-after-approval.txt" >&2
    exit 1
fi
if ! grep -q '"event":"bagModeHelperLedgerSample"' "$helper_smappservice_prepare/evidence/helper-stdout-after-approval.txt" ||
   ! grep -q 'commandJson="status"' "$helper_smappservice_prepare/evidence/helper-stdout-after-approval.txt"; then
    echo "SMAppService helper prototype post-approval stdout capture did not include mirrored helper evidence" >&2
    cat "$helper_smappservice_prepare/evidence/helper-stdout-after-approval.txt" >&2
    exit 1
fi
for post_approval_capture in \
    helper-status-after-approval \
    launchctl-status \
    helper-bootstrap-after-approval \
    helper-stdout-after-approval \
    helper-stderr-after-approval \
    root-ledger-schema-and-permissions \
    root-ledger-ownership-sample \
    log-evidence
do
    if [[ ! -s "$helper_smappservice_prepare/evidence/$post_approval_capture.txt" ]]; then
        echo "SMAppService helper prototype post-approval capture missing evidence: $post_approval_capture" >&2
        exit 1
    fi
    if [[ ! -s "$helper_smappservice_prepare/evidence/$post_approval_capture.status" ]]; then
        echo "SMAppService helper prototype post-approval capture missing status: $post_approval_capture" >&2
        exit 1
    fi
done
for unpromoted_capture_row in \
    helper-status-after-approval \
    helper-bootstrap-after-approval \
    root-ledger-schema-and-permissions \
    root-ledger-ownership-sample \
    launchctl-status \
    log-evidence
do
    if ! awk -F '\t' -v check_id="$unpromoted_capture_row" '$1 == check_id && $2 == "TODO" { found = 1 } END { exit !found }' "$helper_smappservice_prepare/prototype-manifest.tsv"; then
        echo "SMAppService helper prototype post-approval capture should not auto-promote row: $unpromoted_capture_row" >&2
        cat "$helper_smappservice_prepare/prototype-manifest.tsv" >&2
        exit 1
    fi
done
CLAWSHELL_SMAPP_LOG_LAST=1m scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_prepare" --capture-post-reboot >/dev/null
if ! grep -q '^postRebootCaptureAttempted=true$' "$helper_smappservice_prepare/validation-config.txt"; then
    echo "SMAppService helper prototype post-reboot capture did not update validation config" >&2
    cat "$helper_smappservice_prepare/validation-config.txt" >&2
    exit 1
fi
if [[ ! -s "$helper_smappservice_prepare/post-reboot-capture.md" ]]; then
    echo "SMAppService helper prototype post-reboot capture did not write its README" >&2
    exit 1
fi
for post_reboot_capture in \
    helper-status-post-reboot \
    post-reboot-helper-bootstrap \
    launchctl-status-post-reboot \
    helper-bootstrap-post-reboot \
    helper-stdout-post-reboot \
    helper-stderr-post-reboot \
    log-evidence-post-reboot
do
    if [[ ! -s "$helper_smappservice_prepare/evidence/$post_reboot_capture.txt" ]]; then
        echo "SMAppService helper prototype post-reboot capture missing evidence: $post_reboot_capture" >&2
        exit 1
    fi
    if [[ ! -s "$helper_smappservice_prepare/evidence/$post_reboot_capture.status" ]]; then
        echo "SMAppService helper prototype post-reboot capture missing status: $post_reboot_capture" >&2
        exit 1
    fi
done
if ! grep -q "plistName=$helper_smappservice_prepare_label.plist" "$helper_smappservice_prepare/evidence/helper-status-post-reboot.txt"; then
    echo "SMAppService helper prototype post-reboot status did not use the derived plist name" >&2
    cat "$helper_smappservice_prepare/evidence/helper-status-post-reboot.txt" >&2
    exit 1
fi
if ! awk -F '\t' '$1 == "post-reboot-helper-bootstrap" && $2 == "TODO" { found = 1 } END { exit !found }' "$helper_smappservice_prepare/prototype-manifest.tsv"; then
    echo "SMAppService helper prototype post-reboot capture should not auto-promote post-reboot row" >&2
    cat "$helper_smappservice_prepare/prototype-manifest.tsv" >&2
    exit 1
fi
helper_smappservice_capture_symlink_source="$bag_mode_smoke_dir/helper-smappservice-capture-symlink-source"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_symlink_source"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_symlink_source"
rm -f "$helper_smappservice_capture_symlink_source/runtime/helper.log"
ln -s /etc/hosts "$helper_smappservice_capture_symlink_source/runtime/helper.log"
CLAWSHELL_SMAPP_LOG_LAST=1m scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_symlink_source" --capture-post-approval >/dev/null
if ! grep -q "symlinkSource=" "$helper_smappservice_capture_symlink_source/evidence/helper-bootstrap-after-approval.txt"; then
    echo "SMAppService helper prototype post-approval capture followed a symlinked runtime source" >&2
    cat "$helper_smappservice_capture_symlink_source/evidence/helper-bootstrap-after-approval.txt" >&2
    exit 1
fi
if ! grep -q '^exitCode=1$' "$helper_smappservice_capture_symlink_source/evidence/helper-bootstrap-after-approval.status"; then
    echo "SMAppService helper prototype post-approval capture did not fail symlinked runtime source" >&2
    cat "$helper_smappservice_capture_symlink_source/evidence/helper-bootstrap-after-approval.status" >&2
    exit 1
fi
helper_smappservice_capture_non_regular_source="$bag_mode_smoke_dir/helper-smappservice-capture-non-regular-source"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_non_regular_source"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_non_regular_source"
rm -f "$helper_smappservice_capture_non_regular_source/runtime/helper.log"
mkdir "$helper_smappservice_capture_non_regular_source/runtime/helper.log"
CLAWSHELL_SMAPP_LOG_LAST=1m scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_non_regular_source" --capture-post-approval >/dev/null
if ! grep -q "nonRegularSource=" "$helper_smappservice_capture_non_regular_source/evidence/helper-bootstrap-after-approval.txt"; then
    echo "SMAppService helper prototype post-approval capture read a non-regular runtime source" >&2
    cat "$helper_smappservice_capture_non_regular_source/evidence/helper-bootstrap-after-approval.txt" >&2
    exit 1
fi
if ! grep -q '^exitCode=1$' "$helper_smappservice_capture_non_regular_source/evidence/helper-bootstrap-after-approval.status"; then
    echo "SMAppService helper prototype post-approval capture did not fail non-regular runtime source" >&2
    cat "$helper_smappservice_capture_non_regular_source/evidence/helper-bootstrap-after-approval.status" >&2
    exit 1
fi
helper_smappservice_manual_helper="$helper_smappservice_prepare/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototypeDaemon"
helper_smappservice_manual_log="$bag_mode_smoke_dir/helper-smappservice-manual-helper.log"
helper_smappservice_manual_ledger="$bag_mode_smoke_dir/helper-smappservice-manual-helper-ledger.jsonl"
helper_smappservice_manual_stdout="$bag_mode_smoke_dir/helper-smappservice-manual-helper.stdout"
"$helper_smappservice_manual_helper" --daemon --command repair --log "$helper_smappservice_manual_log" --ledger "$helper_smappservice_manual_ledger" >"$helper_smappservice_manual_stdout"
if ! grep -q '"command":"repair"' "$helper_smappservice_manual_ledger"; then
    echo "SMAppService helper prototype daemon did not write dry-run ledger JSON" >&2
    cat "$helper_smappservice_manual_ledger" >&2
    exit 1
fi
if ! grep -q '"event":"bagModeHelperLedgerSample"' "$helper_smappservice_manual_stdout" ||
   ! grep -q '"command":"repair"' "$helper_smappservice_manual_stdout"; then
    echo "SMAppService helper prototype daemon did not mirror dry-run ledger JSON to stdout" >&2
    cat "$helper_smappservice_manual_stdout" >&2
    exit 1
fi
if ! grep -q '"effect":"dry-run"' "$helper_smappservice_manual_ledger"; then
    echo "SMAppService helper prototype daemon ledger did not record dry-run effect" >&2
    cat "$helper_smappservice_manual_ledger" >&2
    exit 1
fi
helper_smappservice_manual_symlink_victim="$bag_mode_smoke_dir/helper-smappservice-manual-symlink-victim"
helper_smappservice_manual_symlink_ledger="$bag_mode_smoke_dir/helper-smappservice-manual-symlink-ledger.jsonl"
printf 'victim-before\n' >"$helper_smappservice_manual_symlink_victim"
ln -s "$helper_smappservice_manual_symlink_victim" "$helper_smappservice_manual_symlink_ledger"
if "$helper_smappservice_manual_helper" --daemon --command repair --log "$bag_mode_smoke_dir/helper-smappservice-manual-symlink-ledger.log" --ledger "$helper_smappservice_manual_symlink_ledger" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype daemon followed symlinked ledger path" >&2
    exit 1
fi
if ! grep -q "ledgerWriteError=unsafe-or-unwritable" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if [[ "$(cat "$helper_smappservice_manual_symlink_victim")" != "victim-before" ]]; then
    echo "SMAppService helper prototype daemon modified symlink ledger victim" >&2
    cat "$helper_smappservice_manual_symlink_victim" >&2
    exit 1
fi
helper_smappservice_manual_symlink_parent="$bag_mode_smoke_dir/helper-smappservice-manual-symlink-parent"
helper_smappservice_manual_symlink_parent_target="$bag_mode_smoke_dir/helper-smappservice-manual-symlink-parent-target"
mkdir -p "$helper_smappservice_manual_symlink_parent_target"
ln -s "$helper_smappservice_manual_symlink_parent_target" "$helper_smappservice_manual_symlink_parent"
if "$helper_smappservice_manual_helper" --daemon --command repair --log "$bag_mode_smoke_dir/helper-smappservice-manual-symlink-parent.log" --ledger "$helper_smappservice_manual_symlink_parent/helper-ledger.jsonl" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype daemon followed symlinked ledger parent" >&2
    exit 1
fi
if ! grep -q "ledgerWriteError=unsafe-or-unwritable" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if [[ -e "$helper_smappservice_manual_symlink_parent_target/helper-ledger.jsonl" ]]; then
    echo "SMAppService helper prototype daemon wrote through symlinked ledger parent" >&2
    cat "$helper_smappservice_manual_symlink_parent_target/helper-ledger.jsonl" >&2
    exit 1
fi
helper_smappservice_manual_symlink_log="$bag_mode_smoke_dir/helper-smappservice-manual-symlink.log"
helper_smappservice_manual_log_victim="$bag_mode_smoke_dir/helper-smappservice-manual-log-victim"
printf 'victim-before\n' >"$helper_smappservice_manual_log_victim"
ln -s "$helper_smappservice_manual_log_victim" "$helper_smappservice_manual_symlink_log"
if "$helper_smappservice_manual_helper" --daemon --command repair --log "$helper_smappservice_manual_symlink_log" --ledger "$bag_mode_smoke_dir/helper-smappservice-manual-symlink-log-ledger.jsonl" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype daemon followed symlinked log path" >&2
    exit 1
fi
if ! grep -q "logWriteError=unsafe-or-unwritable" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if [[ "$(cat "$helper_smappservice_manual_log_victim")" != "victim-before" ]]; then
    echo "SMAppService helper prototype daemon modified symlink log victim" >&2
    cat "$helper_smappservice_manual_log_victim" >&2
    exit 1
fi
helper_smappservice_unregister_without_ack="$bag_mode_smoke_dir/helper-smappservice-unregister-without-ack"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_unregister_without_ack" --unregister >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness allowed unregister without acknowledgement" >&2
    exit 1
fi
if ! grep -q -- "--i-understand-this-registers-helper" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_unregister_without_ack="$bag_mode_smoke_dir/helper-smappservice-capture-unregister-without-ack"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_capture_unregister_without_ack" --capture-unregister >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness allowed unregister capture without acknowledgement" >&2
    exit 1
fi
if ! grep -q -- "--i-understand-this-registers-helper" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_prepare" --capture-post-approval --capture-unregister --i-understand-this-registers-helper >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness allowed combined append capture modes" >&2
    exit 1
fi
if ! grep -q "Use only one" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_unregister_symlink_executable="$bag_mode_smoke_dir/helper-smappservice-capture-unregister-symlink-executable"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_unregister_symlink_executable"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_unregister_symlink_executable"
rm -f "$helper_smappservice_capture_unregister_symlink_executable/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototype"
ln -s /bin/echo "$helper_smappservice_capture_unregister_symlink_executable/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototype"
if scripts/helper-service-smappservice-prototype.sh \
    --output-dir "$helper_smappservice_capture_unregister_symlink_executable" \
    --capture-unregister \
    --i-understand-this-registers-helper >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype unregister capture ran a symlinked controller path" >&2
    exit 1
fi
if ! grep -q "regular executable artifact path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_unregister_non_regular_executable="$bag_mode_smoke_dir/helper-smappservice-capture-unregister-non-regular-executable"
cp -R "$helper_smappservice_prepare" "$helper_smappservice_capture_unregister_non_regular_executable"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_unregister_non_regular_executable"
rm -f "$helper_smappservice_capture_unregister_non_regular_executable/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototype"
mkdir "$helper_smappservice_capture_unregister_non_regular_executable/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototype"
if scripts/helper-service-smappservice-prototype.sh \
    --output-dir "$helper_smappservice_capture_unregister_non_regular_executable" \
    --capture-unregister \
    --i-understand-this-registers-helper >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype unregister capture ran a non-regular controller path" >&2
    exit 1
fi
if ! grep -q "regular executable artifact path" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_capture_unregister_fake="$bag_mode_smoke_dir/helper-smappservice-capture-unregister-fake"
mkdir -p "$helper_smappservice_capture_unregister_fake/ClawShellHelperPrototype.app/Contents/MacOS" \
    "$helper_smappservice_capture_unregister_fake/ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons" \
    "$helper_smappservice_capture_unregister_fake/evidence" \
    "$helper_smappservice_capture_unregister_fake/runtime"
cp "$helper_smappservice_prepare/ClawShellHelperPrototype.app/Contents/Info.plist" \
    "$helper_smappservice_capture_unregister_fake/ClawShellHelperPrototype.app/Contents/Info.plist"
cp "$helper_smappservice_prepare/ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons/$helper_smappservice_prepare_label.plist" \
    "$helper_smappservice_capture_unregister_fake/ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons/$helper_smappservice_prepare_label.plist"
rebase_helper_smappservice_launchdaemon "$helper_smappservice_capture_unregister_fake"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'command="${1:-status}"'
    printf '%s\n' 'echo "command=$command"'
    printf 'echo "plistName=%s.plist"\n' "$helper_smappservice_prepare_label"
    printf '%s\n' 'case "$command" in'
    printf '%s\n' '  unregister)'
    printf '%s\n' '    echo "statusBeforeRaw=1"'
    printf '%s\n' '    echo "statusBeforeDescription=SMAppServiceStatus(rawValue: 1)"'
    printf '%s\n' '    echo "unregisterResult=success"'
    printf '%s\n' '    echo "statusAfterRaw=0"'
    printf '%s\n' '    echo "statusAfterDescription=SMAppServiceStatus(rawValue: 0)"'
    printf '%s\n' '    ;;'
    printf '%s\n' '  status)'
    printf '%s\n' '    echo "statusBeforeRaw=0"'
    printf '%s\n' '    echo "statusBeforeDescription=SMAppServiceStatus(rawValue: 0)"'
    printf '%s\n' '    echo "statusAfterRaw=0"'
    printf '%s\n' '    echo "statusAfterDescription=SMAppServiceStatus(rawValue: 0)"'
    printf '%s\n' '    ;;'
    printf '%s\n' '  *) exit 64 ;;'
    printf '%s\n' 'esac'
} >"$helper_smappservice_capture_unregister_fake/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototype"
printf '#!/usr/bin/env bash\nexit 0\n' >"$helper_smappservice_capture_unregister_fake/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototypeDaemon"
chmod +x "$helper_smappservice_capture_unregister_fake/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototype" \
    "$helper_smappservice_capture_unregister_fake/ClawShellHelperPrototype.app/Contents/MacOS/ClawShellHelperPrototypeDaemon"
{
    printf 'evidenceFormat=helper-prototype-v1\n'
    printf 'appBundleIdentifier=com.makeavish.ClawShell.HelperPrototype.%s\n' "$helper_smappservice_prepare_identity"
    printf 'helperLabel=%s\n' "$helper_smappservice_prepare_label"
    printf 'identitySuffix=%s\n' "$helper_smappservice_prepare_identity"
    printf 'daemonCommand=status\n'
    printf 'rootLedgerPath=runtime/helper-ledger.jsonl\n'
    printf 'unregisterAttempted=false\n'
} >"$helper_smappservice_capture_unregister_fake/validation-config.txt"
cp "$helper_smappservice_prepare/prototype-manifest.tsv" "$helper_smappservice_capture_unregister_fake/prototype-manifest.tsv"
CLAWSHELL_SMAPP_LOG_LAST=1m scripts/helper-service-smappservice-prototype.sh \
    --output-dir "$helper_smappservice_capture_unregister_fake" \
    --capture-unregister \
    --i-understand-this-registers-helper >/dev/null
if ! grep -q '^unregisterAttempted=true$' "$helper_smappservice_capture_unregister_fake/validation-config.txt"; then
    echo "SMAppService helper prototype unregister capture did not update unregisterAttempted" >&2
    cat "$helper_smappservice_capture_unregister_fake/validation-config.txt" >&2
    exit 1
fi
if ! grep -q '^unregisterCaptureAttempted=true$' "$helper_smappservice_capture_unregister_fake/validation-config.txt"; then
    echo "SMAppService helper prototype unregister capture did not update unregisterCaptureAttempted" >&2
    cat "$helper_smappservice_capture_unregister_fake/validation-config.txt" >&2
    exit 1
fi
for unregister_capture in \
    helper-uninstall \
    helper-status-after-unregister \
    launchctl-status-after-unregister \
    log-evidence-after-unregister
do
    if [[ ! -s "$helper_smappservice_capture_unregister_fake/evidence/$unregister_capture.txt" ]]; then
        echo "SMAppService helper prototype unregister capture missing evidence: $unregister_capture" >&2
        exit 1
    fi
    if [[ ! -s "$helper_smappservice_capture_unregister_fake/evidence/$unregister_capture.status" ]]; then
        echo "SMAppService helper prototype unregister capture missing status: $unregister_capture" >&2
        exit 1
    fi
done
for unpromoted_unregister_row in \
    helper-uninstall \
    helper-uninstall-state-cleanup
do
    if ! awk -F '\t' -v check_id="$unpromoted_unregister_row" '$1 == check_id && $2 == "TODO" { found = 1 } END { exit !found }' "$helper_smappservice_capture_unregister_fake/prototype-manifest.tsv"; then
        echo "SMAppService helper prototype unregister capture should not auto-promote row: $unpromoted_unregister_row" >&2
        cat "$helper_smappservice_capture_unregister_fake/prototype-manifest.tsv" >&2
        exit 1
    fi
done
if [[ ! -s "$helper_smappservice_capture_unregister_fake/unregister-capture.md" ]]; then
    echo "SMAppService helper prototype unregister capture missing summary" >&2
    exit 1
fi
helper_smappservice_file="$bag_mode_smoke_dir/helper-smappservice-file"
touch "$helper_smappservice_file"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_file" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness accepted an output path that is not a directory" >&2
    exit 1
fi
if ! grep -q "not a directory" "$bag_mode_smoke_error"; then
    cat "$bag_mode_smoke_error" >&2
    exit 1
fi
helper_smappservice_non_empty="$bag_mode_smoke_dir/helper-smappservice-non-empty"
mkdir -p "$helper_smappservice_non_empty"
touch "$helper_smappservice_non_empty/existing"
if scripts/helper-service-smappservice-prototype.sh --output-dir "$helper_smappservice_non_empty" >/dev/null 2>"$bag_mode_smoke_error"; then
    echo "SMAppService helper prototype harness overwrote a non-empty output directory" >&2
    exit 1
fi
if ! grep -q "Output directory is not empty" "$bag_mode_smoke_error"; then
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
: >"$helper_prototype_empty_dir/evidence/app-signing-or-auth-model.txt"
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
echo 'TODO paste output here' >"$helper_prototype_placeholder_evidence_dir/evidence/app-signing-or-auth-model.txt"
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
rm "$helper_prototype_symlink_dir/evidence/app-signing-or-auth-model.txt"
ln -s /etc/hosts "$helper_prototype_symlink_dir/evidence/app-signing-or-auth-model.txt"
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
mkdir "$helper_prototype_dir_symlink_dir/evidence/app-signing-or-auth-model-dir"
printf '$ app signing/auth model\ncaptured app signing/auth output\n' >"$helper_prototype_dir_symlink_dir/evidence/app-signing-or-auth-model-dir/output.txt"
ln -s /etc/hosts "$helper_prototype_dir_symlink_dir/evidence/app-signing-or-auth-model-dir/escaped-hosts"
sed -i '' 's#app-signing-or-auth-model	evidence	evidence/app-signing-or-auth-model.txt#app-signing-or-auth-model	evidence	evidence/app-signing-or-auth-model-dir#' "$helper_prototype_dir_symlink_dir/prototype-manifest.tsv"
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
