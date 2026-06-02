import Foundation

public enum IntegrationPatchOperation: String, Equatable, Sendable {
    case install
    case remove
}

public struct IntegrationPatcherManifest: Equatable, Sendable {
    public var agentID: String
    public var patcherVersion: Int
    public var targetFiles: [String]
    public var ownerMarker: String
    public var backupPolicy: String
    public var removalStrategy: String

    public init(
        agentID: String,
        patcherVersion: Int = 1,
        targetFiles: [String],
        ownerMarker: String,
        backupPolicy: String = "timestamped-before-first-mutation",
        removalStrategy: String = "remove-owned-block-only"
    ) {
        self.agentID = agentID
        self.patcherVersion = patcherVersion
        self.targetFiles = targetFiles
        self.ownerMarker = ownerMarker
        self.backupPolicy = backupPolicy
        self.removalStrategy = removalStrategy
    }
}

public struct IntegrationPatchPlan: Equatable, Sendable {
    public var operation: IntegrationPatchOperation
    public var manifest: IntegrationPatcherManifest
    public var dryRunDiff: [String]
    public var patchedData: Data
    public var backupRequired: Bool

    public init(
        operation: IntegrationPatchOperation,
        manifest: IntegrationPatcherManifest,
        dryRunDiff: [String],
        patchedData: Data,
        backupRequired: Bool
    ) {
        self.operation = operation
        self.manifest = manifest
        self.dryRunDiff = dryRunDiff
        self.patchedData = patchedData
        self.backupRequired = backupRequired
    }
}

public enum IntegrationPatcherError: Error, Equatable, LocalizedError {
    case invalidJSON
    case invalidEncoding
    case invalidTOML(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Integration patcher could not parse JSON."
        case .invalidEncoding:
            "Integration patcher could not decode the config as UTF-8."
        case .invalidTOML(let message):
            "Integration patcher could not update TOML: \(message)"
        }
    }
}

public struct ClaudeCodeConfigPatcher {
    public static let manifest = IntegrationPatcherManifest(
        agentID: AgentKind.claudeCode.rawValue,
        targetFiles: ["~/.claude/settings.json"],
        ownerMarker: "com.agentwake.integration.claude-code.v1"
    )

    private let encoder: JSONEncoder

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func installPlan(currentData: Data, adapterPath: String) throws -> IntegrationPatchPlan {
        var root = try mutableJSONObject(from: currentData)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for event in Self.claudeHookEvents {
            let existingGroups = hooks[event] as? [[String: Any]] ?? []
            var groups = removeOwnedClaudeHooks(from: existingGroups).groups
            let command = Self.command(adapterPath: adapterPath, ownerMarker: Self.manifest.ownerMarker)
            groups.append(Self.hookGroup(command: command, includeMatcher: Self.claudeToolHookEvents.contains(event)))
            hooks[event] = groups
        }

        root["hooks"] = hooks
        let patched = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return IntegrationPatchPlan(
            operation: .install,
            manifest: Self.manifest,
            dryRunDiff: ["install owned Claude Code hooks for \(Self.claudeHookEvents.joined(separator: ", "))"],
            patchedData: patched,
            backupRequired: !currentData.isEmpty
        )
    }

    public func removalPlan(currentData: Data) throws -> IntegrationPatchPlan {
        var root = try mutableJSONObject(from: currentData)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var removedOwnedHooks = false

        for event in Self.claudeHookEvents {
            guard let existingGroups = hooks[event] as? [[String: Any]] else {
                continue
            }

            let result = removeOwnedClaudeHooks(from: existingGroups)
            guard result.removedOwnedHook else {
                continue
            }

            removedOwnedHooks = true
            if result.groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = result.groups
            }
        }

        guard removedOwnedHooks else {
            return IntegrationPatchPlan(
                operation: .remove,
                manifest: Self.manifest,
                dryRunDiff: ["remove owned Claude Code hooks only"],
                patchedData: currentData,
                backupRequired: false
            )
        }

        root["hooks"] = hooks
        let patched = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return IntegrationPatchPlan(
            operation: .remove,
            manifest: Self.manifest,
            dryRunDiff: ["remove owned Claude Code hooks only"],
            patchedData: patched,
            backupRequired: !currentData.isEmpty
        )
    }

    public func validate(_ data: Data) throws {
        _ = try mutableJSONObject(from: data)
    }

    private static let claudeHookEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
        "StopFailure",
        "SessionEnd"
    ]
    private static let claudeToolHookEvents: Set<String> = [
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure"
    ]

    private static func command(adapterPath: String, ownerMarker: String) -> String {
        [
            shellQuote(adapterPath),
            "--mode", "claude-hook",
            "--agent", AgentKind.claudeCode.rawValue,
            "--host", AgentKind.claudeCode.rawValue,
            "--owner-marker", ownerMarker
        ].joined(separator: " ")
    }

    private static func hookGroup(command: String, includeMatcher: Bool) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": command
                ]
            ]
        ]

        if includeMatcher {
            group["matcher"] = "*"
        }

        return group
    }

    private func removeOwnedClaudeHooks(from groups: [[String: Any]]) -> (groups: [[String: Any]], removedOwnedHook: Bool) {
        var removedOwnedHook = false
        let groups = groups.compactMap { group -> [String: Any]? in
            guard let handlers = group["hooks"] as? [[String: Any]] else {
                return group
            }

            let retainedHandlers = handlers.filter { handler in
                let command = handler["command"] as? String
                let isOwned = Self.isOwnedClaudeCommand(command)
                removedOwnedHook = removedOwnedHook || isOwned
                return !isOwned
            }

            guard !retainedHandlers.isEmpty else {
                return nil
            }

            var next = group
            next["hooks"] = retainedHandlers
            return next
        }

        return (groups, removedOwnedHook)
    }

    private static func isOwnedClaudeCommand(_ command: String?) -> Bool {
        guard let command else {
            return false
        }

        return command.contains("AgentWakeHookAdapter")
            && command.contains("--mode claude-hook")
            && command.contains("--owner-marker \(manifest.ownerMarker)")
    }

    private func mutableJSONObject(from data: Data) throws -> [String: Any] {
        guard !data.isEmpty else {
            return [:]
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntegrationPatcherError.invalidJSON
        }

        return object
    }
}

public struct CodexConfigPatcher {
    public static let manifest = IntegrationPatcherManifest(
        agentID: AgentKind.codexCLI.rawValue,
        targetFiles: ["~/.codex/config.toml"],
        ownerMarker: "com.agentwake.integration.codex-cli.v1"
    )

    public init() {}

    public func installPlan(currentData: Data, adapterPath: String) throws -> IntegrationPatchPlan {
        let content = try utf8String(from: currentData)
        let cleaned = try removeOwnedBlock(from: content).content
        let previousNotify = topLevelNotifyLine(in: cleaned)
        let notifyBlock = try Self.ownedNotifyBlock(adapterPath: adapterPath, previousNotifyText: previousNotify?.text)
        let hooksBlock = Self.ownedHooksBlock(adapterPath: adapterPath)
        let patched = insertOwnedBlocks(notifyBlock: notifyBlock, hooksBlock: hooksBlock, replacing: previousNotify, in: cleaned)

        return IntegrationPatchPlan(
            operation: .install,
            manifest: Self.manifest,
            dryRunDiff: ["install Codex native hooks plus notify command with previous notify forwarding"],
            patchedData: Data(patched.utf8),
            backupRequired: !currentData.isEmpty
        )
    }

    public func removalPlan(currentData: Data) throws -> IntegrationPatchPlan {
        let content = try utf8String(from: currentData)
        let result = try removeOwnedBlock(from: content)
        return IntegrationPatchPlan(
            operation: .remove,
            manifest: Self.manifest,
            dryRunDiff: ["remove owned Codex notify block and restore previous notify when recorded"],
            patchedData: Data(result.content.utf8),
            backupRequired: result.removed && !currentData.isEmpty
        )
    }

    public func validate(_ data: Data) throws {
        let content = try utf8String(from: data)
        _ = try Self.ownedBlockRanges(in: content)
        if let notifyLine = topLevelNotifyLine(in: content) {
            try Self.validateNotifyAssignment(notifyLine.text)
        }
        try Self.validateNoDuplicateTopLevelKeys(in: content)
    }

    private static let beginMarker = "# BEGIN \(manifest.ownerMarker)"
    private static let endMarker = "# END \(manifest.ownerMarker)"
    private static let previousNotifyPrefix = "# agentwake-previous-notify-base64: "
    private static let codexHookEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Stop"
    ]

    private static func ownedNotifyBlock(adapterPath: String, previousNotifyText: String?) throws -> String {
        let previousNotifyBase64 = previousNotifyText
            .map { Data($0.utf8).base64EncodedString() } ?? "none"
        let previousNotifyArray: [String]
        if let previousNotifyText {
            previousNotifyArray = try parseNotifyArray(from: previousNotifyText)
        } else {
            previousNotifyArray = []
        }
        let forwardArgument = previousNotifyArray.isEmpty ? nil : codableStringArrayBase64(previousNotifyArray)
        var notifyCommand = [
            adapterPath,
            "--mode",
            "codex-notify",
            "--agent",
            AgentKind.codexCLI.rawValue,
            "--host",
            AgentKind.codexCLI.rawValue,
            "--owner-marker",
            manifest.ownerMarker
        ]

        if let forwardArgument {
            notifyCommand += ["--forward-notify", forwardArgument]
        }

        return [
            beginMarker,
            "# AgentWake owns this top-level Codex notify fallback.",
            "\(previousNotifyPrefix)\(previousNotifyBase64)",
            "notify = \(tomlArray(notifyCommand))",
            endMarker
        ].joined(separator: "\n")
    }

    private static func ownedHooksBlock(adapterPath: String) -> String {
        var lines = [
            beginMarker,
            "# AgentWake owns these Codex native hooks.",
            "# Existing user hooks are preserved outside this owned block.",
            ""
        ]
        let hookCommand = Self.codexHookCommand(adapterPath: adapterPath)
        for event in codexHookEvents {
            lines.append("[[hooks.\(event)]]")
            lines.append("[[hooks.\(event).hooks]]")
            lines.append("type = \"command\"")
            lines.append("command = \(tomlString(hookCommand))")
            lines.append("timeout = 1")
            lines.append("")
        }

        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    private static func codexHookCommand(adapterPath: String) -> String {
        [
            shellQuote(adapterPath),
            "--mode",
            "codex-hook",
            "--agent",
            AgentKind.codexCLI.rawValue,
            "--host",
            AgentKind.codexCLI.rawValue,
            "--owner-marker",
            shellQuote(manifest.ownerMarker)
        ].joined(separator: " ")
    }

    private func insertOwnedBlocks(
        notifyBlock: String,
        hooksBlock: String,
        replacing notifyLine: (range: Range<String.Index>, text: String)?,
        in content: String
    ) -> String {
        let withNotify: String
        if let notifyLine {
            var next = content
            next.replaceSubrange(notifyLine.range, with: ensureTrailingNewline(notifyBlock))
            withNotify = next
        } else {
            withNotify = notifyBlock + (content.isEmpty ? "" : "\n" + content)
        }

        return ensureTrailingNewline(ensureTrailingNewline(withNotify) + "\n" + hooksBlock)
    }

    private func removeOwnedBlock(from content: String) throws -> (content: String, removed: Bool) {
        let blockRanges = try Self.ownedBlockRanges(in: content)
        guard !blockRanges.isEmpty else {
            return (content, false)
        }

        // If an external `notify =` already exists outside our owned block(s) (e.g. a
        // third-party tool wrote a top-level notify on top of ours), skip restoring the
        // recorded previous-notify — emitting it would create a duplicate `notify =`
        // key and produce invalid TOML.
        let strippedContent = stringExcluding(ranges: blockRanges, from: content)
        let shouldRestorePreviousNotify = topLevelNotifyLine(in: strippedContent) == nil

        var next = ""
        var cursor = content.startIndex
        for blockRange in blockRanges {
            next.append(contentsOf: content[cursor..<blockRange.lowerBound])
            if shouldRestorePreviousNotify {
                let block = String(content[blockRange])
                if let restoredNotify = previousNotifyLine(from: block) {
                    next.append(ensureTrailingNewline(restoredNotify))
                }
            }
            cursor = blockRange.upperBound
        }
        next.append(contentsOf: content[cursor..<content.endIndex])

        let compacted = next.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        guard !compacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("", true)
        }
        return (ensureTrailingNewline(compacted), true)
    }

    private func stringExcluding(ranges: [Range<String.Index>], from content: String) -> String {
        var result = ""
        var cursor = content.startIndex
        for range in ranges {
            result.append(contentsOf: content[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        result.append(contentsOf: content[cursor..<content.endIndex])
        return result
    }

    private func previousNotifyLine(from block: String) -> String? {
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix(Self.previousNotifyPrefix) else {
                continue
            }

            let raw = String(line.dropFirst(Self.previousNotifyPrefix.count))
            guard raw != "none",
                  let data = Data(base64Encoded: raw),
                  let restored = String(data: data, encoding: .utf8),
                  !restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            return restored
        }

        return nil
    }

    private func topLevelNotifyLine(in content: String) -> (range: Range<String.Index>, text: String)? {
        var cursor = content.startIndex
        var inTopLevel = true

        while cursor < content.endIndex {
            let lineEnd = content[cursor...].firstIndex(of: "\n") ?? content.endIndex
            let lineRange = cursor..<lineEnd
            let line = String(content[lineRange])
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") {
                inTopLevel = false
            }

            if inTopLevel, trimmed.hasPrefix("notify") {
                let noWhitespace = trimmed.filter { !$0.isWhitespace }
                if noWhitespace.hasPrefix("notify=") {
                    let assignmentEnd = notifyAssignmentEnd(startingAt: cursor, in: content)
                    return (cursor..<assignmentEnd, String(content[cursor..<assignmentEnd]).trimmingCharacters(in: .newlines))
                }
            }

            cursor = lineEnd < content.endIndex ? content.index(after: lineEnd) : content.endIndex
        }

        return nil
    }

    private static func parseNotifyArray(from text: String) throws -> [String] {
        guard let equals = text.firstIndex(of: "=") else {
            throw IntegrationPatcherError.invalidTOML("notify assignment is missing '='")
        }

        let rhs = text[text.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard rhs.hasPrefix("[") else {
            throw IntegrationPatcherError.invalidTOML("notify assignment must be an array")
        }
        try validateNotifyArrayRemainder(String(rhs))

        guard let values = parseTomlStringArray(rhs) else {
            throw IntegrationPatcherError.invalidTOML("notify array must contain parseable string values")
        }

        return values
    }

    private static func validateNoDuplicateTopLevelKeys(in content: String) throws {
        // Scope: catches the realistic class of duplicate-key corruption seen in
        // Codex config files (e.g. an external tool writes a second top-level
        // `notify =` on top of one already present). Codex configs don't use
        // multi-line triple-quoted strings or other constructs that would defeat
        // a simple line-based scanner, so we keep this minimal — the upstream
        // `topLevelNotifyLine` has the same limitation.
        var seen: Set<String> = []
        var inTopLevel = true
        var cursor = content.startIndex

        while cursor < content.endIndex {
            let lineEnd = content[cursor...].firstIndex(of: "\n") ?? content.endIndex
            let trimmed = String(content[cursor..<lineEnd]).trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") {
                inTopLevel = false
            } else if inTopLevel, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                if let key = topLevelBareKey(from: trimmed), !seen.insert(key).inserted {
                    throw IntegrationPatcherError.invalidTOML("duplicate top-level key '\(key)'")
                }
            }

            cursor = lineEnd < content.endIndex ? content.index(after: lineEnd) : content.endIndex
        }
    }

    private static func topLevelBareKey(from trimmedLine: String) -> String? {
        guard let equals = trimmedLine.firstIndex(of: "=") else {
            return nil
        }
        let keyPart = trimmedLine[..<equals].trimmingCharacters(in: .whitespaces)
        guard !keyPart.isEmpty else {
            return nil
        }
        // TOML bare keys: ASCII letters, digits, underscore, dash. Dot is allowed for
        // dotted keys (e.g. `apple.color = "red"`). Quoted keys are intentionally
        // ignored here — they're rare at top level and don't collide with the bare
        // keys we care about (e.g. `notify`).
        guard keyPart.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        return keyPart
    }

    private static func validateNotifyAssignment(_ text: String) throws {
        guard let equals = text.firstIndex(of: "=") else {
            throw IntegrationPatcherError.invalidTOML("notify assignment is missing '='")
        }

        let rhs = text[text.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard rhs.hasPrefix("[") else {
            throw IntegrationPatcherError.invalidTOML("notify assignment must be an array")
        }

        try validateNotifyArrayRemainder(String(rhs))
    }

    private static func validateNotifyArrayRemainder(_ raw: String) throws {
        guard let closingBracket = tomlArrayClosingBracket(in: raw) else {
            throw IntegrationPatcherError.invalidTOML("notify array must be closed")
        }

        let remainderStart = raw.index(after: closingBracket)
        var cursor = remainderStart
        while cursor < raw.endIndex {
            let character = raw[cursor]
            if character == "#" {
                return
            }
            guard character.isWhitespace else {
                throw IntegrationPatcherError.invalidTOML("notify assignment has trailing content after array")
            }
            cursor = raw.index(after: cursor)
        }
    }

    private static func ownedBlockRanges(in content: String) throws -> [Range<String.Index>] {
        let ranges = try ownedBlockRanges(
            in: content,
            beginMarker: beginMarker,
            endMarker: endMarker
        )

        return mergedRanges(ranges.sorted { $0.lowerBound < $1.lowerBound })
    }

    private static func mergedRanges(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var merged: [Range<String.Index>] = []

        for range in ranges {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }

            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }

        return merged
    }

    private static func ownedBlockRanges(
        in content: String,
        beginMarker: String,
        endMarker: String
    ) throws -> [Range<String.Index>] {
        let begins = lineRanges(equalTo: beginMarker, in: content)
        let ends = endMarkerRanges(in: content, endMarker: endMarker)
        guard begins.count == ends.count else {
            throw IntegrationPatcherError.invalidTOML("owned block markers are unbalanced")
        }

        var ranges: [Range<String.Index>] = []
        var endCursor = ends.startIndex

        for begin in begins {
            while endCursor < ends.endIndex, ends[endCursor].lowerBound < begin.upperBound {
                throw IntegrationPatcherError.invalidTOML("owned block markers are misordered")
            }

            guard endCursor < ends.endIndex else {
                throw IntegrationPatcherError.invalidTOML("owned block is missing an end marker")
            }

            let end = ends[endCursor]
            if begins.contains(where: { $0.lowerBound > begin.lowerBound && $0.lowerBound < end.lowerBound }) {
                throw IntegrationPatcherError.invalidTOML("owned block markers are nested")
            }

            ranges.append(begin.lowerBound..<end.upperBound)
            endCursor = ends.index(after: endCursor)
        }

        return ranges
    }

    private static func endMarkerRanges(in content: String, endMarker: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = content.startIndex

        while cursor < content.endIndex {
            let lineEnd = content[cursor...].firstIndex(of: "\n") ?? content.endIndex
            let rangeEnd = lineEnd < content.endIndex ? content.index(after: lineEnd) : lineEnd
            let rawLine = content[cursor..<lineEnd]
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)

            if line == endMarker {
                ranges.append(cursor..<rangeEnd)
            } else if line.hasPrefix(endMarker) {
                let suffix = line.dropFirst(endMarker.count)
                if suffix.first == "[",
                   let markerRange = rawLine.range(of: endMarker),
                   rawLine[..<markerRange.lowerBound].allSatisfy({ $0.isWhitespace }) {
                    ranges.append(cursor..<markerRange.upperBound)
                }
            }

            cursor = rangeEnd
        }

        return ranges
    }
}

public enum IntegrationConfigWriter {
    public static func write(_ plan: IntegrationPatchPlan, to url: URL, fileManager: FileManager = .default) throws {
        if plan.backupRequired, fileManager.fileExists(atPath: url.path) {
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).agentwake-backup.\(Int(Date().timeIntervalSince1970)).\(UUID().uuidString)")
            try fileManager.copyItem(at: url, to: backupURL)
        }

        try AtomicFileWriter.write(plan.patchedData, to: url, fileManager: fileManager)
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func tomlArray(_ values: [String]) -> String {
    "[" + values.map(tomlString).joined(separator: ", ") + "]"
}

private func tomlString(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func codableStringArrayBase64(_ values: [String]) -> String? {
    guard let data = try? JSONEncoder().encode(values) else {
        return nil
    }

    return data.base64EncodedString()
}

private func parseTomlStringArray(_ raw: String) -> [String]? {
    var values: [String] = []
    var current = ""
    var stringDelimiter: Character?
    var escaped = false
    var hasOpenedArray = false
    var inComment = false

    for character in raw {
        if inComment {
            if character == "\n" {
                inComment = false
            }
            continue
        }

        if !hasOpenedArray {
            guard character == "[" else {
                continue
            }
            hasOpenedArray = true
            continue
        }

        if let delimiter = stringDelimiter {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }

            if delimiter == "\"" && character == "\\" {
                escaped = true
                continue
            }

            if character == delimiter {
                values.append(current)
                current = ""
                stringDelimiter = nil
                continue
            }

            current.append(character)
            continue
        }

        if character == "#" {
            inComment = true
            continue
        }

        if character == "\"" || character == "'" {
            stringDelimiter = character
            continue
        }

        if character == "]" {
            return values
        }
    }

    return nil
}

private func tomlArrayClosingBracket(in raw: String) -> String.Index? {
    var cursor = raw.startIndex
    var stringDelimiter: Character?
    var escaped = false
    var hasOpenedArray = false
    var bracketDepth = 0
    var inComment = false

    while cursor < raw.endIndex {
        let character = raw[cursor]

        if inComment {
            if character == "\n" {
                inComment = false
            }
        } else if let delimiter = stringDelimiter {
            if escaped {
                escaped = false
            } else if delimiter == "\"" && character == "\\" {
                escaped = true
            } else if character == delimiter {
                stringDelimiter = nil
            }
        } else if !hasOpenedArray {
            if character.isWhitespace {
                cursor = raw.index(after: cursor)
                continue
            }

            guard character == "[" else {
                return nil
            }

            hasOpenedArray = true
            bracketDepth = 1
        } else if character == "#" {
            inComment = true
        } else if character == "\"" || character == "'" {
            stringDelimiter = character
        } else if character == "[" {
            bracketDepth += 1
        } else if character == "]" {
            bracketDepth -= 1
            if bracketDepth == 0 {
                return cursor
            }
        }

        cursor = raw.index(after: cursor)
    }

    return nil
}

private func notifyAssignmentEnd(startingAt start: String.Index, in content: String) -> String.Index {
    var cursor = start
    var bracketDepth = 0
    var stringDelimiter: Character?
    var escaped = false
    var sawArray = false
    var inComment = false

    while cursor < content.endIndex {
        let character = content[cursor]

        if inComment {
            if character == "\n" {
                inComment = false
            }
        } else if let delimiter = stringDelimiter {
            if escaped {
                escaped = false
            } else if delimiter == "\"" && character == "\\" {
                escaped = true
            } else if character == delimiter {
                stringDelimiter = nil
            }
        } else if character == "\"" || character == "'" {
            stringDelimiter = character
        } else if character == "#" {
            inComment = true
        } else if character == "[" {
            bracketDepth += 1
            sawArray = true
        } else if character == "]" {
            bracketDepth = max(0, bracketDepth - 1)
            if sawArray && bracketDepth == 0 {
                let lineEnd = content[cursor...].firstIndex(of: "\n") ?? content.endIndex
                return lineEnd < content.endIndex ? content.index(after: lineEnd) : lineEnd
            }
        } else if character == "\n", !sawArray {
            return content.index(after: cursor)
        }

        cursor = content.index(after: cursor)
    }

    return content.endIndex
}

private func lineRanges(equalTo marker: String, in content: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var cursor = content.startIndex

    while cursor < content.endIndex {
        let lineEnd = content[cursor...].firstIndex(of: "\n") ?? content.endIndex
        let rangeEnd = lineEnd < content.endIndex ? content.index(after: lineEnd) : lineEnd
        let line = String(content[cursor..<lineEnd]).trimmingCharacters(in: .whitespaces)
        if line == marker {
            ranges.append(cursor..<rangeEnd)
        }
        cursor = rangeEnd
    }

    return ranges
}

private func utf8String(from data: Data) throws -> String {
    guard !data.isEmpty else {
        return ""
    }

    guard let content = String(data: data, encoding: .utf8) else {
        throw IntegrationPatcherError.invalidEncoding
    }

    return content
}

private func ensureTrailingNewline(_ value: String) -> String {
    value.hasSuffix("\n") ? value : value + "\n"
}
