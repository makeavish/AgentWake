#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/helper-service-smappservice-prototype.sh ..." >&2
    exit 2
fi
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/helper-service-smappservice-prototype.sh --output-dir DIR [--case-id ID]
       scripts/helper-service-smappservice-prototype.sh --output-dir DIR --register --i-understand-this-registers-helper
       scripts/helper-service-smappservice-prototype.sh --output-dir DIR --unregister --i-understand-this-registers-helper

Builds a no-membership SMAppService helper prototype evidence package for #27.
The default mode is non-mutating: it builds an ad-hoc signed app/helper bundle,
captures layout/signing/status evidence, and leaves lifecycle rows as TODO.

--register and --unregister call SMAppService and can change local helper state.
Use them only during an intentional #27 prototype run.
USAGE
}

OUTPUT_DIR=""
CASE_ID="apple-silicon-smappservice-local"
REGISTER=false
UNREGISTER=false
ALLOW_MUTATION=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --output-dir)
            [[ "$#" -ge 2 ]] || { echo "--output-dir requires a value" >&2; exit 64; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --case-id)
            [[ "$#" -ge 2 ]] || { echo "--case-id requires a value" >&2; exit 64; }
            CASE_ID="$2"
            shift 2
            ;;
        --register)
            REGISTER=true
            shift
            ;;
        --unregister)
            UNREGISTER=true
            shift
            ;;
        --i-understand-this-registers-helper)
            ALLOW_MUTATION=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
    usage >&2
    exit 64
fi
if [[ "$REGISTER" == true && "$UNREGISTER" == true ]]; then
    echo "Use only one of --register or --unregister per run." >&2
    exit 64
fi
if [[ ( "$REGISTER" == true || "$UNREGISTER" == true ) && "$ALLOW_MUTATION" != true ]]; then
    echo "--register/--unregister require --i-understand-this-registers-helper" >&2
    exit 64
fi
if [[ -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ]]; then
    echo "Output path exists but is not a directory: $OUTPUT_DIR" >&2
    exit 73
fi
if [[ -e "$OUTPUT_DIR" && -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    echo "Output directory is not empty: $OUTPUT_DIR" >&2
    exit 73
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

BUNDLE_ID="com.makeavish.ClawShell.HelperPrototype"
HELPER_LABEL="com.makeavish.ClawShell.HelperPrototype.daemon"
APP_NAME="ClawShellHelperPrototype"
HELPER_NAME="ClawShellHelperPrototypeDaemon"
PLIST_NAME="$HELPER_LABEL.plist"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
LAUNCHD_DIR="$CONTENTS_DIR/Library/LaunchDaemons"
RUNTIME_DIR="$OUTPUT_DIR/runtime"
SOURCE_DIR="$OUTPUT_DIR/source-package"
EVIDENCE_DIR="$OUTPUT_DIR/evidence"

mkdir -p "$MACOS_DIR" "$LAUNCHD_DIR" "$RUNTIME_DIR" "$SOURCE_DIR" "$EVIDENCE_DIR"

if [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

CODESIGN="$(xcrun --find codesign)"

capture() {
    local name="$1"
    shift
    local out="$EVIDENCE_DIR/$name.txt"
    local status_file="$EVIDENCE_DIR/$name.status"
    local start finish status
    start="$(date +%s)"
    set +e
    {
        printf '$'
        printf ' %q' "$@"
        printf '\n'
        "$@"
    } >"$out" 2>&1
    status=$?
    set -e
    finish="$(date +%s)"
    local command_parts=("$@")
    {
        printf 'command='
        printf '%q' "${command_parts[0]}"
        for part in "${command_parts[@]:1}"; do
            printf ' %q' "$part"
        done
        printf '\n'
        echo "exitCode=$status"
        echo "durationSeconds=$(( finish - start ))"
    } >"$status_file"
    return "$status"
}

capture_required() {
    local name="$1"
    if ! capture "$@"; then
        echo "Required evidence capture failed: $name" >&2
        cat "$EVIDENCE_DIR/$name.txt" >&2
        exit 1
    fi
}

capture_optional() {
    capture "$@" || true
}

capture_caller_auth_model() {
    local out="$EVIDENCE_DIR/caller-auth-model.txt"
    local status_file="$EVIDENCE_DIR/caller-auth-model.status"
    local start finish status
    start="$(date +%s)"
    set +e
    {
        printf '$ shasum -a 256 %q %q\n' "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/$HELPER_NAME"
        shasum -a 256 "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/$HELPER_NAME"
        status=$?
        if [[ "$status" -eq 0 ]]; then
            printf '$ stat -f %q %q %q %q\n' \
                'mode=%Sp owner=%Su group=%Sg path=%N' \
                "$APP_DIR" \
                "$MACOS_DIR/$APP_NAME" \
                "$MACOS_DIR/$HELPER_NAME"
            stat -f 'mode=%Sp owner=%Su group=%Sg path=%N' \
                "$APP_DIR" \
                "$MACOS_DIR/$APP_NAME" \
                "$MACOS_DIR/$HELPER_NAME"
            status=$?
        fi
    } >"$out" 2>&1
    set -e
    finish="$(date +%s)"
    {
        echo "command=caller-auth-model"
        echo "exitCode=$status"
        echo "durationSeconds=$(( finish - start ))"
    } >"$status_file"
    return "$status"
}

capture_caller_auth_model_required() {
    if ! capture_caller_auth_model; then
        echo "Required evidence capture failed: caller-auth-model" >&2
        cat "$EVIDENCE_DIR/caller-auth-model.txt" >&2
        exit 1
    fi
}

capture_fixed_command_api() {
    local out="$EVIDENCE_DIR/fixed-command-api.txt"
    local status_file="$EVIDENCE_DIR/fixed-command-api.status"
    local log_file="$RUNTIME_DIR/fixed-command-api.log"
    local start finish status block_status rc command rejected_command
    local allowed_commands=(status enableBagMode disableBagMode repair uninstall)
    start="$(date +%s)"
    status=0
    rejected_command="arbitraryShellCommand"
    set +e
    {
        for command in "${allowed_commands[@]}"; do
            printf '$ %q --command %q --log %q\n' "$MACOS_DIR/$HELPER_NAME" "$command" "$log_file"
            "$MACOS_DIR/$HELPER_NAME" --command "$command" --log "$log_file"
            rc=$?
            echo "observedExitCode[$command]=$rc"
            if [[ "$rc" -ne 0 ]]; then
                status=1
            fi
        done

        printf '$ %q --command %q --log %q\n' "$MACOS_DIR/$HELPER_NAME" "$rejected_command" "$log_file"
        "$MACOS_DIR/$HELPER_NAME" --command "$rejected_command" --log "$log_file"
        rc=$?
        echo "observedExitCode[$rejected_command]=$rc"
        if [[ "$rc" -eq 0 ]]; then
            status=1
        fi
    } >"$out" 2>&1
    block_status=$?
    set -e
    if [[ "$block_status" -ne 0 ]]; then
        status=1
    fi
    finish="$(date +%s)"
    {
        echo "command=fixed-command-api"
        echo "exitCode=$status"
        echo "durationSeconds=$(( finish - start ))"
    } >"$status_file"
    return "$status"
}

capture_fixed_command_api_required() {
    if ! capture_fixed_command_api; then
        echo "Required evidence capture failed: fixed-command-api" >&2
        cat "$EVIDENCE_DIR/fixed-command-api.txt" >&2
        exit 1
    fi
}

xml_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    printf '%s' "$value"
}

write_controller_source() {
    mkdir -p "$SOURCE_DIR/Sources/ClawShellHelperPrototype"
    cat >"$SOURCE_DIR/Sources/ClawShellHelperPrototype/main.swift" <<'SWIFT'
import Foundation
import ServiceManagement

@main
struct Controller {
    static func main() {
        guard #available(macOS 13.0, *) else {
            print("error=SMAppService requires macOS 13 or newer")
            exit(2)
        }

        let plistName = "com.makeavish.ClawShell.HelperPrototype.daemon.plist"
        let service = SMAppService.daemon(plistName: plistName)
        let command = CommandLine.arguments.dropFirst().first ?? "status"

        print("command=\(command)")
        print("plistName=\(plistName)")
        print("statusBeforeRaw=\(service.status.rawValue)")
        print("statusBeforeDescription=\(String(describing: service.status))")

        do {
            switch command {
            case "status":
                break
            case "register":
                try service.register()
                print("registerResult=success")
            case "unregister":
                try service.unregister()
                print("unregisterResult=success")
            default:
                print("error=unknown command: \(command)")
                exit(64)
            }
            print("statusAfterRaw=\(service.status.rawValue)")
            print("statusAfterDescription=\(String(describing: service.status))")
        } catch {
            print("errorType=\(String(reflecting: type(of: error)))")
            print("errorDescription=\(error.localizedDescription)")
            print("error=\(String(reflecting: error))")
            print("statusAfterRaw=\(service.status.rawValue)")
            print("statusAfterDescription=\(String(describing: service.status))")
            exit(1)
        }
    }
}
SWIFT
}

write_helper_source() {
    mkdir -p "$SOURCE_DIR/Sources/ClawShellHelperPrototypeDaemon"
    cat >"$SOURCE_DIR/Sources/ClawShellHelperPrototypeDaemon/main.swift" <<'SWIFT'
import Foundation
import Darwin

let arguments = CommandLine.arguments
let allowedCommands: Set<String> = [
    "status",
    "enableBagMode",
    "disableBagMode",
    "repair",
    "uninstall"
]

func argumentValue(after option: String) -> String? {
    guard let index = arguments.firstIndex(of: option) else {
        return nil
    }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else {
        return nil
    }
    return arguments[valueIndex]
}

func jsonValue(_ value: String) -> String {
    guard JSONSerialization.isValidJSONObject([value]),
          let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
          let encoded = String(data: data, encoding: .utf8) else {
        return "\"<encoding-failed>\""
    }
    return String(encoded.dropFirst().dropLast())
}

func jsonArray(_ values: [String]) -> String {
    guard JSONSerialization.isValidJSONObject(values),
          let data = try? JSONSerialization.data(withJSONObject: values, options: []),
          let encoded = String(data: data, encoding: .utf8) else {
        return "[\"<encoding-failed>\"]"
    }
    return encoded
}

let command = argumentValue(after: "--command") ?? "status"
let commandAllowed = allowedCommands.contains(command)
let logPath = argumentValue(after: "--log")
let payload = """
event=helper-command
timestampUtc=\(ISO8601DateFormatter().string(from: Date()))
pid=\(getpid())
uid=\(getuid())
euid=\(geteuid())
commandJson=\(jsonValue(command))
allowed=\(commandAllowed)
effect=dry-run
argumentsJson=\(jsonArray(arguments))

"""

if let logPath {
    let url = URL(fileURLWithPath: logPath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = payload.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath),
           let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

print(payload, terminator: "")
if !commandAllowed {
    exit(64)
}
SWIFT
}

write_package_manifest() {
    cat >"$SOURCE_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClawShellHelperPrototypePackage",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ClawShellHelperPrototype",
            targets: ["ClawShellHelperPrototype"]
        ),
        .executable(
            name: "ClawShellHelperPrototypeDaemon",
            targets: ["ClawShellHelperPrototypeDaemon"]
        )
    ],
    targets: [
        .executableTarget(name: "ClawShellHelperPrototype"),
        .executableTarget(name: "ClawShellHelperPrototypeDaemon")
    ]
)
SWIFT
}

write_info_plist() {
    cat >"$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF
}

write_launchdaemon_plist() {
    local helper_path helper_log stdout_log stderr_log
    helper_path="$(xml_escape "$MACOS_DIR/$HELPER_NAME")"
    helper_log="$(xml_escape "$RUNTIME_DIR/helper.log")"
    stdout_log="$(xml_escape "$RUNTIME_DIR/helper.stdout.log")"
    stderr_log="$(xml_escape "$RUNTIME_DIR/helper.stderr.log")"
    cat >"$LAUNCHD_DIR/$PLIST_NAME" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$HELPER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$helper_path</string>
    <string>--daemon</string>
    <string>--log</string>
    <string>$helper_log</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$stdout_log</string>
  <key>StandardErrorPath</key>
  <string>$stderr_log</string>
</dict>
</plist>
EOF
}

write_package_manifest
write_controller_source
write_helper_source
write_info_plist
write_launchdaemon_plist

swift build --package-path "$SOURCE_DIR" --product "$APP_NAME" >"$EVIDENCE_DIR/swift-build-controller.txt" 2>&1
swift build --package-path "$SOURCE_DIR" --product "$HELPER_NAME" >"$EVIDENCE_DIR/swift-build-helper.txt" 2>&1
BIN_DIR="$(swift build --package-path "$SOURCE_DIR" --show-bin-path)"
cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$BIN_DIR/$HELPER_NAME" "$MACOS_DIR/$HELPER_NAME"

capture_required "app-bundle-or-install-layout" find "$APP_DIR" -maxdepth 5 -print
capture_required "launchdaemon-plist" plutil -p "$LAUNCHD_DIR/$PLIST_NAME"
capture_optional "app-signing-or-auth-model-before-sign" "$CODESIGN" -dvvv "$APP_DIR"

"$CODESIGN" --force --sign - "$MACOS_DIR/$APP_NAME" >/dev/null 2>"$EVIDENCE_DIR/controller-codesign.stderr"
"$CODESIGN" --force --sign - "$MACOS_DIR/$HELPER_NAME" >/dev/null 2>"$EVIDENCE_DIR/helper-codesign.stderr"
"$CODESIGN" --force --sign - --deep "$APP_DIR" >/dev/null 2>"$EVIDENCE_DIR/app-bundle-codesign.stderr"

capture_required "app-signing-or-auth-model" "$CODESIGN" -dvvv "$APP_DIR"
capture_required "helper-signing-or-auth-model" "$CODESIGN" -dvvv "$MACOS_DIR/$HELPER_NAME"
capture_caller_auth_model_required
capture_fixed_command_api_required
capture_optional "spctl-or-gatekeeper-assessment" spctl -a -vv "$APP_DIR"
capture_required "helper-status-before-approval" "$MACOS_DIR/$APP_NAME" status

REGISTER_EXIT=0
REGISTER_EVIDENCE_STATUS="TODO"
REGISTER_EVIDENCE_PATH=""
REGISTER_NOTE="Run --register --i-understand-this-registers-helper during the interactive #27 prototype"

if [[ "$REGISTER" == true ]]; then
    capture "helper-install-or-register" "$MACOS_DIR/$APP_NAME" register || true
    REGISTER_EXIT="$(sed -n 's/^exitCode=//p' "$EVIDENCE_DIR/helper-install-or-register.status" | head -n 1)"
    REGISTER_EVIDENCE_STATUS="evidence"
    REGISTER_EVIDENCE_PATH="evidence/helper-install-or-register.txt"
    REGISTER_NOTE="SMAppService register attempted; inspect status and System Settings approval state"
elif [[ "$UNREGISTER" == true ]]; then
    capture "helper-uninstall" "$MACOS_DIR/$APP_NAME" unregister || true
fi

MACOS_VERSION="$(sw_vers -productVersion)"
HELPER_INSTALL_PATH="smappservice"
RESULT="inconclusive"
if [[ "$REGISTER" == true && "$REGISTER_EXIT" != "0" ]]; then
    RESULT="fail"
fi

cat >"$OUTPUT_DIR/validation-config.txt" <<EOF
evidenceFormat=helper-prototype-v1
metadataRedacted=true
macOSVersion=$MACOS_VERSION
appBundleIdentifier=$BUNDLE_ID
helperLabel=$HELPER_LABEL
launchDaemonPlist=$APP_NAME.app/Contents/Library/LaunchDaemons/$PLIST_NAME
helperInstallPath=$HELPER_INSTALL_PATH
localAuthModel=ad-hoc app/helper signature plus binary hash capture; pairing token not implemented in this prototype harness
developerIDApplicationSigned=false
packageInstallerUsed=false
homebrewCaskUsed=false
result=$RESULT
caseId=$CASE_ID
registerAttempted=$REGISTER
unregisterAttempted=$UNREGISTER
EOF

cat >"$OUTPUT_DIR/manual-result.md" <<EOF
# Helper Service Prototype Result

## Prototype Case
- Case ID: $CASE_ID
- macOS: $MACOS_VERSION
- App bundle: $APP_DIR
- LaunchDaemon plist: $APP_NAME.app/Contents/Library/LaunchDaemons/$PLIST_NAME
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
- Install/status transition: TODO - run register and capture requiresApproval/enabled state
- Admin approval/password flow confirmed: TODO - approve in System Settings if register succeeds
- Helper bootstraps after approval: TODO
- Helper bootstraps after reboot: TODO
- Old helper inactive after update: TODO
- Ledger compatibility or repair checked: TODO
- Uninstall unloaded helper: TODO
- Helper-owned Bag Mode state removed: TODO

## Failure Cases
- Failure cases recorded: TODO
- Homebrew cask used: no
- Homebrew cask registers helper during install: N/A - cask not used

## Conclusion
- Result: $RESULT
EOF

manifest_row() {
    local check_id="$1"
    local status="$2"
    local path="$3"
    local note="$4"
    printf '%s\t%s\t%s\t%s\n' "$check_id" "$status" "$path" "$note"
}

{
    printf 'checkId\tstatus\tevidencePath\tnote\n'
    manifest_row "app-bundle-or-install-layout" "evidence" "evidence/app-bundle-or-install-layout.txt" "prototype app bundle built"
    manifest_row "launchdaemon-plist" "evidence" "evidence/launchdaemon-plist.txt" "bundled LaunchDaemon plist captured"
    manifest_row "app-signing-or-auth-model" "evidence" "evidence/app-signing-or-auth-model.txt" "ad-hoc app signature captured"
    manifest_row "helper-signing-or-auth-model" "evidence" "evidence/helper-signing-or-auth-model.txt" "ad-hoc helper signature captured"
    manifest_row "caller-auth-model" "evidence" "evidence/caller-auth-model.txt" "binary hashes captured; pairing token not implemented"
    manifest_row "fixed-command-api" "TODO" "" "Dry-run command parser smoke captured at evidence/fixed-command-api.txt; replace with approved helper command evidence"
    manifest_row "spctl-or-gatekeeper-assessment" "evidence" "evidence/spctl-or-gatekeeper-assessment.txt" "Gatekeeper assessment captured"
    manifest_row "helper-install-or-register" "$REGISTER_EVIDENCE_STATUS" "$REGISTER_EVIDENCE_PATH" "$REGISTER_NOTE"
    manifest_row "helper-status-after-approval" "TODO" "" "Capture after System Settings approval or fallback bootstrap"
    manifest_row "admin-approval-or-password-flow" "TODO" "" "Capture approval flow during interactive prototype"
    manifest_row "helper-bootstrap-after-approval" "TODO" "" "Capture helper runtime log after approval"
    manifest_row "post-reboot-helper-bootstrap" "TODO" "" "Capture after reboot"
    manifest_row "root-ledger-schema-and-permissions" "TODO" "" "Implement/capture root ledger"
    manifest_row "root-ledger-ownership-sample" "TODO" "" "Capture root ledger sample"
    manifest_row "helper-update-old-inactive" "TODO" "" "Exercise update"
    manifest_row "helper-update-ledger-compatibility" "TODO" "" "Exercise update ledger compatibility"
    manifest_row "helper-repair-conflict" "TODO" "" "Exercise repair/conflict"
    if [[ "$UNREGISTER" == true ]]; then
        manifest_row "helper-uninstall" "evidence" "evidence/helper-uninstall.txt" "SMAppService unregister attempted"
    else
        manifest_row "helper-uninstall" "TODO" "" "Run unregister during cleanup evidence"
    fi
    manifest_row "helper-uninstall-state-cleanup" "TODO" "" "Capture cleanup"
    manifest_row "cli-helper-status-repair-uninstall" "TODO" "" "Capture CLI helper commands"
    manifest_row "failure-unpaired-caller" "TODO" "" "Exercise caller auth failure"
    manifest_row "failure-wrong-bundle-id-or-label" "TODO" "" "Exercise bundle/label failure"
    manifest_row "failure-wrong-user" "TODO" "" "Exercise wrong user failure"
    manifest_row "failure-stale-app-version" "TODO" "" "Exercise stale app failure"
    manifest_row "failure-denied-or-revoked-approval" "TODO" "" "Exercise denied/revoked approval"
    manifest_row "launchctl-status" "TODO" "" "Capture launchctl state after approval/bootstrap"
    manifest_row "log-evidence" "TODO" "" "Capture unified logs and helper logs"
    if [[ "$REGISTER" == true && "$REGISTER_EXIT" != "0" ]]; then
        manifest_row "smappservice-rejection" "evidence" "evidence/helper-install-or-register.txt" "register failed; inspect whether fallback is justified"
    else
        manifest_row "smappservice-rejection" "n/a" "" "SMAppService fallback not selected in this package"
    fi
    manifest_row "package-installer-signing" "n/a" "" "No package installer used"
    manifest_row "homebrew-cask-semantics" "n/a" "" "No Homebrew cask used"
} >"$OUTPUT_DIR/prototype-manifest.tsv"

OUTPUT_DIR_ARG="$(printf '%q' "$OUTPUT_DIR")"
README_INVOCATION="scripts/helper-service-smappservice-prototype.sh \\
  --output-dir $OUTPUT_DIR_ARG"
MODE_NOTICE="This artifact was produced in non-mutating prepare mode. It did not call SMAppService register or unregister."
if [[ "$REGISTER" == true ]]; then
    README_INVOCATION="$README_INVOCATION \\
  --register \\
  --i-understand-this-registers-helper"
    MODE_NOTICE="This artifact was produced in mutating register mode. It attempted SMAppService registration and may require System Settings approval or cleanup."
elif [[ "$UNREGISTER" == true ]]; then
    README_INVOCATION="$README_INVOCATION \\
  --unregister \\
  --i-understand-this-registers-helper"
    MODE_NOTICE="This artifact was produced in mutating unregister mode. It attempted SMAppService unregistration and should be treated as cleanup evidence."
fi

cat >"$OUTPUT_DIR/README.md" <<EOF
# SMAppService Helper Prototype Artifact

This artifact was produced by:

\`\`\`sh
$README_INVOCATION
\`\`\`

$MODE_NOTICE

This is not complete #27 evidence. It prepares an ad-hoc signed app/helper
bundle and records local status, signing, layout, dry-run command parser smoke,
and Gatekeeper evidence.

To attempt registration, run a new artifact with:

\`\`\`sh
scripts/helper-service-smappservice-prototype.sh \\
  --output-dir .build/helper-service-prototype/smappservice-register-\$(date -u +%Y%m%dT%H%M%SZ) \\
  --register \\
  --i-understand-this-registers-helper
\`\`\`

Registration may require System Settings approval before the helper bootstraps.
EOF

echo "SMAppService helper prototype artifact written to $OUTPUT_DIR"
echo "Verifier is expected to fail until TODO lifecycle rows are replaced with real evidence."
