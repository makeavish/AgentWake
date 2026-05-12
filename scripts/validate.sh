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
