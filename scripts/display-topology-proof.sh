#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/display-topology-proof.sh ..." >&2
    exit 2
fi

usage() {
    cat <<'EOF'
Usage: scripts/display-topology-proof.sh --output-dir DIR [--input-json PATH]

Captures or parses macOS display topology evidence for #120 external-display
availability. The artifact records redacted display facts and marks external
display rows N/A when no external display is attached in the captured topology.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR=""
INPUT_JSON=""
INPUT_JSON_TEMP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            if [[ $# -lt 2 || "${2:-}" == --* ]]; then
                echo "--output-dir requires a value" >&2
                usage >&2
                exit 2
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --input-json)
            if [[ $# -lt 2 || "${2:-}" == --* ]]; then
                echo "--input-json requires a value" >&2
                usage >&2
                exit 2
            fi
            INPUT_JSON="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
    echo "--output-dir is required" >&2
    usage >&2
    exit 2
fi

case "$OUTPUT_DIR" in
    /*) ;;
    *) OUTPUT_DIR="$PWD/$OUTPUT_DIR" ;;
esac
while [[ "$OUTPUT_DIR" != "/" && "$OUTPUT_DIR" == */ ]]; do
    OUTPUT_DIR="${OUTPUT_DIR%/}"
done

owned_artifacts=(
    validation-config.txt
    display-topology.tsv
    external-display-manifest.tsv
    summary.md
)

if [[ -L "$OUTPUT_DIR" ]]; then
    echo "Output directory must not be a symlink: $OUTPUT_DIR" >&2
    exit 1
fi
if [[ -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ]]; then
    echo "Output path is not a directory: $OUTPUT_DIR" >&2
    exit 1
fi
if [[ -d "$OUTPUT_DIR" ]]; then
    while IFS= read -r -d '' existing_entry; do
        existing_name="$(basename "$existing_entry")"
        allowed=false
        for owned_artifact in "${owned_artifacts[@]}"; do
            if [[ "$existing_name" == "$owned_artifact" ]]; then
                allowed=true
                break
            fi
        done
        if [[ "$existing_name" == ".DS_Store" ]]; then
            allowed=true
        fi
        if [[ "$allowed" != "true" ]]; then
            echo "Output directory contains unexpected file: $existing_entry" >&2
            exit 1
        fi
    done < <(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print0)
    for owned_artifact in "${owned_artifacts[@]}"; do
        rm -f "$OUTPUT_DIR/$owned_artifact"
    done
else
    mkdir -p "$OUTPUT_DIR"
fi

if [[ -z "$INPUT_JSON" ]]; then
    INPUT_JSON_TEMP="$(mktemp)"
    INPUT_JSON="$INPUT_JSON_TEMP"
    /usr/sbin/system_profiler SPDisplaysDataType -json >"$INPUT_JSON"
fi
trap '[[ -n "$INPUT_JSON_TEMP" ]] && rm -f "$INPUT_JSON_TEMP"' EXIT

case "$INPUT_JSON" in
    /*) ;;
    *) INPUT_JSON="$PWD/$INPUT_JSON" ;;
esac

if [[ ! -s "$INPUT_JSON" ]]; then
    echo "Input display JSON is missing or empty: $INPUT_JSON" >&2
    exit 1
fi

cd "$ROOT_DIR"
swift - "$INPUT_JSON" "$OUTPUT_DIR" <<'SWIFT'
import Foundation

struct DisplayRecord {
    var name: String
    var connectionType: String
    var displayType: String
    var online: Bool
    var main: Bool
    var resolution: String

    var isInternal: Bool {
        connectionType == "spdisplays_internal" || displayType.contains("built-in")
    }

    var isExternal: Bool {
        !isInternal
    }
}

func stringValue(_ dictionary: [String: Any], _ key: String) -> String {
    dictionary[key] as? String ?? "unknown"
}

func boolValue(_ dictionary: [String: Any], _ key: String) -> Bool {
    guard let value = dictionary[key] as? String else {
        return false
    }
    return value == "spdisplays_yes"
}

func write(_ text: String, to url: URL) throws {
    guard let data = text.data(using: .utf8) else {
        throw NSError(domain: "display-topology-proof", code: 1)
    }
    try data.write(to: url, options: [.atomic])
}

func run() throws {
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: swift display parser INPUT_JSON OUTPUT_DIR\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
let data = try Data(contentsOf: inputURL)
let json = try JSONSerialization.jsonObject(with: data)
guard let root = json as? [String: Any] else {
    throw NSError(domain: "display-topology-proof", code: 2)
}

let gpuEntries = root["SPDisplaysDataType"] as? [[String: Any]] ?? []
let displays = gpuEntries.flatMap { gpu -> [DisplayRecord] in
    let rawDisplays = gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? []
    return rawDisplays.map { display in
        DisplayRecord(
            name: stringValue(display, "_name"),
            connectionType: stringValue(display, "spdisplays_connection_type"),
            displayType: stringValue(display, "spdisplays_display_type"),
            online: boolValue(display, "spdisplays_online"),
            main: boolValue(display, "spdisplays_main"),
            resolution: stringValue(display, "_spdisplays_resolution")
        )
    }
}

let onlineDisplays = displays.filter(\.online)
let internalCount = onlineDisplays.filter(\.isInternal).count
let externalCount = onlineDisplays.filter(\.isExternal).count
let topology: String
if externalCount > 0 {
    topology = "external-display"
} else if internalCount > 0 {
    topology = "internal-only"
} else {
    topology = "no-external-display"
}

let manifestReason = externalCount == 0
    ? "No external display detected in current SPDisplaysDataType snapshot"
    : "External display detected; manual Closed-Lid Mode lifecycle evidence still required"

let config = """
evidenceFormat=display-topology-proof-v1
metadataRedacted=true
source=SPDisplaysDataType-json
displayTopology=\(topology)
onlineDisplayCount=\(onlineDisplays.count)
internalDisplayCount=\(internalCount)
externalDisplayCount=\(externalCount)
externalDisplayRowsNA=\(externalCount == 0)
result=pass
"""
try write(config + "\n", to: outputURL.appendingPathComponent("validation-config.txt"))

var displayLines = [
    ["displayLabel", "connectionType", "displayType", "online", "main", "resolution"].joined(separator: "\t")
]
displayLines.append(contentsOf: displays.enumerated().map { index, display in
    [
        "display-\(index + 1)",
        display.connectionType,
        display.displayType,
        String(display.online),
        String(display.main),
        display.resolution
    ].joined(separator: "\t")
})
try write(displayLines.joined(separator: "\n") + "\n", to: outputURL.appendingPathComponent("display-topology.tsv"))

let externalStatus = externalCount == 0 ? "n/a" : "deferred"
let manifest = """
caseId\tstatus\tevidenceDir\tnaReason
apple-silicon-ac-external-display-normal\t\(externalStatus)\t\t\(manifestReason)
apple-silicon-battery-external-display-normal\t\(externalStatus)\t\t\(manifestReason)
"""
try write(manifest + "\n", to: outputURL.appendingPathComponent("external-display-manifest.tsv"))

let summary = """
# Display Topology Proof

- Result: pass
- Display topology: \(topology)
- Online displays: \(onlineDisplays.count)
- Internal displays: \(internalCount)
- External displays: \(externalCount)
- External display rows N/A: \(externalCount == 0)

## Boundary

This artifact proves only the captured display topology and whether external-display Closed-Lid Mode rows are physically available right now. It does not exercise lid-close behavior, power settings, or external-display Closed-Lid Mode lifecycle behavior.
"""
try write(summary + "\n", to: outputURL.appendingPathComponent("summary.md"))
}

do {
    try run()
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
SWIFT

for required in validation-config.txt display-topology.tsv external-display-manifest.tsv summary.md; do
    if [[ ! -s "$OUTPUT_DIR/$required" ]]; then
        echo "Display topology proof missing required artifact: $required" >&2
        exit 1
    fi
done

if ! grep -qx 'result=pass' "$OUTPUT_DIR/validation-config.txt"; then
    echo "Display topology proof did not pass" >&2
    exit 1
fi

echo "Display topology proof written to $OUTPUT_DIR"
