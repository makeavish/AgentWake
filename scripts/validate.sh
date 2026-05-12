#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

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

echo "==> bag mode primitive harness smoke"
bag_mode_smoke_dir="$(mktemp -d)"
bag_mode_smoke_error="$(mktemp)"
test_list_output=""
test_list_error=""
temperature_validation_before=""
trap '[[ -n "$test_list_output" ]] && rm -f "$test_list_output"; [[ -n "$test_list_error" ]] && rm -f "$test_list_error"; [[ -n "$temperature_validation_before" ]] && rm -f "$temperature_validation_before"; rm -f "$bag_mode_smoke_error"; rm -rf "$bag_mode_smoke_dir"' EXIT

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

if swift test list >"$test_list_output" 2>"$test_list_error"; then
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
    swift test
else
    if grep -q 'This toolchain does not provide Testing or XCTest' "$test_list_error"; then
        echo "==> swift test skipped: this toolchain does not provide Testing or XCTest"
    else
        cat "$test_list_error" >&2
        exit 1
    fi
fi
