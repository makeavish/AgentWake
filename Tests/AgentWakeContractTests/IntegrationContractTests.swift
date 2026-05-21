import Foundation

#if canImport(Testing)
import Testing
@testable import AgentWakeCore

struct IntegrationContractTests {
    @Test func adapterReducesClaudePayloadWithoutSensitiveFields() throws {
        try runAdapterReducesClaudePayloadWithoutSensitiveFields()
    }

    @Test func adapterReducesCodexNativeHooksWithoutSensitiveFields() throws {
        try runAdapterReducesCodexNativeHooksWithoutSensitiveFields()
    }

    @Test func adapterNoOpsWhenControlEndpointIsUnavailable() throws {
        try runAdapterNoOpsWhenControlEndpointIsUnavailable()
    }

    @Test func configPatchersPreserveAndRemoveOnlyOwnedBlocks() throws {
        try runConfigPatchersPreserveAndRemoveOnlyOwnedBlocks()
    }
}

#elseif canImport(XCTest)
import XCTest
@testable import AgentWakeCore

final class IntegrationContractTests: XCTestCase {
    func testAdapterReducesClaudePayloadWithoutSensitiveFields() throws {
        try runAdapterReducesClaudePayloadWithoutSensitiveFields()
    }

    func testAdapterReducesCodexNativeHooksWithoutSensitiveFields() throws {
        try runAdapterReducesCodexNativeHooksWithoutSensitiveFields()
    }

    func testAdapterNoOpsWhenControlEndpointIsUnavailable() throws {
        try runAdapterNoOpsWhenControlEndpointIsUnavailable()
    }

    func testConfigPatchersPreserveAndRemoveOnlyOwnedBlocks() throws {
        try runConfigPatchersPreserveAndRemoveOnlyOwnedBlocks()
    }
}

#else
#error("This toolchain does not provide Testing or XCTest. Run `swift run AgentWakeCoreChecks` for portable checks.")
#endif

#if canImport(Testing) || canImport(XCTest)
private func runAdapterReducesClaudePayloadWithoutSensitiveFields() throws {
    let payload = try fixtureData("adapters/claude-pre-tool-use", extension: "json")
    let event = try checkNotNil(
        HookAdapterMapper.claudeCodeEvent(
            from: payload,
            context: HookAdapterContext(
                agent: .claudeCode,
                host: "claude-code",
                processID: 101,
                cwdHashSalt: "contract-salt",
                eventIDProvider: { "fallback" }
            )
        ),
        "Expected fixture payload to map to an AgentWake event"
    )
    let encoded = try String(data: JSONEncoder().encode(event), encoding: .utf8) ?? ""

    try check(event.event == .toolStarted, "Expected PreToolUse to map to tool_started")
    try check(encoded.contains("claude-code"), "Expected reduced event to keep agent identity")
    for sensitive in ["secret prompt", "npm test", "private-project", "transcript", "tool_input"] {
        try check(!encoded.contains(sensitive), "Expected reduced event to exclude \(sensitive)")
    }

    let nativeToolPayload = Data(#"{"hook_event_name":"PreToolUse","session_id":"contract-session","tool_use_id":"tool-1"}"#.utf8)
    let nativeToolEvent = try checkNotNil(
        HookAdapterMapper.claudeCodeEvent(
            from: nativeToolPayload,
            context: HookAdapterContext(
                agent: .claudeCode,
                host: "claude-code",
                processID: 101,
                cwdHashSalt: "contract-salt",
                eventIDProvider: { "fallback" }
            )
        ),
        "Expected native tool payload to map to an AgentWake event"
    )
    let replayedNativeToolEvent = try checkNotNil(
        HookAdapterMapper.claudeCodeEvent(
            from: nativeToolPayload,
            context: HookAdapterContext(
                agent: .claudeCode,
                host: "claude-code",
                processID: 101,
                cwdHashSalt: "contract-salt",
                eventIDProvider: { "different-fallback" }
            )
        ),
        "Expected replayed native tool payload to map to an AgentWake event"
    )
    try check(nativeToolEvent.eventID == replayedNativeToolEvent.eventID, "Expected Claude tool payloads with occurrence IDs to get stable replay IDs")
}

private func runAdapterReducesCodexNativeHooksWithoutSensitiveFields() throws {
    let cases: [(fixture: String, event: HookAdapterEventKind, sessionID: String)] = [
        ("codex-session-start", .sessionStarted, "codex-session-1"),
        ("codex-user-prompt-submit", .turnStarted, "codex-turn-1"),
        ("codex-pre-tool-use", .toolStarted, "codex-turn-1"),
        ("codex-post-tool-use", .toolFinishedContinuing, "codex-turn-1"),
        ("codex-stop", .turnFinished, "codex-turn-1")
    ]

    for testCase in cases {
        let event = try checkNotNil(
            HookAdapterMapper.codexHookEvent(
                from: fixtureData("adapters/\(testCase.fixture)", extension: "json"),
                context: HookAdapterContext(
                    agent: .codexCLI,
                    host: "codex-cli",
                    processID: 202,
                    cwdHashSalt: "contract-salt",
                    eventIDProvider: { "fallback-\(testCase.fixture)" }
                )
            ),
            "Expected \(testCase.fixture) to map to an AgentWake event"
        )
        let encoded = try String(data: JSONEncoder().encode(event), encoding: .utf8) ?? ""

        try check(event.agent == .codexCLI, "Expected Codex native hook to keep Codex agent identity")
        try check(event.event == testCase.event, "Expected \(testCase.fixture) to map to \(testCase.event.rawValue)")
        try check(event.pid == 202, "Expected Codex native hook to carry resolved process id")
        try check(event.integrationSessionId == testCase.sessionID, "Expected Codex native hook to prefer turn id when present")
        try check(event.cwdHash == CWDHash.hmacSHA256("/Users/tester/private-codex-project", salt: "contract-salt"), "Expected Codex cwd to be HMAC hashed")
        try check(event.eventID.hasPrefix("codex-"), "Expected Codex native hook replay IDs to be namespaced")

        for sensitive in ["secret prompt text", "cat .env", "SECRET_TOKEN", "private-codex-project", "transcript", "assistant message"] {
            try check(!encoded.contains(sensitive), "Expected reduced Codex event to exclude \(sensitive)")
        }
    }

    let replayPayload = try fixtureData("adapters/codex-pre-tool-use", extension: "json")
    let first = try checkNotNil(
        HookAdapterMapper.codexHookEvent(
            from: replayPayload,
            context: HookAdapterContext(agent: .codexCLI, host: "codex-cli", cwdHashSalt: "contract-salt")
        ),
        "Expected first Codex tool payload to map"
    )
    let second = try checkNotNil(
        HookAdapterMapper.codexHookEvent(
            from: replayPayload,
            context: HookAdapterContext(agent: .codexCLI, host: "codex-cli", cwdHashSalt: "contract-salt")
        ),
        "Expected replayed Codex tool payload to map"
    )
    try check(first.eventID == second.eventID, "Expected Codex native hook occurrence IDs to produce stable replay IDs")

    let rawEventID = try checkNotNil(
        HookAdapterMapper.codexHookEvent(
            from: Data(#"{"hook_event_name":"PreToolUse","event_id":"raw-sensitive-event-id","session_id":"contract-session","turn_id":"contract-turn","tool_use_id":"tool-1"}"#.utf8),
            context: HookAdapterContext(agent: .codexCLI, host: "codex-cli", cwdHashSalt: "contract-salt")
        ),
        "Expected Codex native hook with raw event_id to map"
    )
    try check(rawEventID.eventID.hasPrefix("codex-"), "Expected raw Codex event_id to be HMAC namespaced")
    try check(rawEventID.eventID != "raw-sensitive-event-id", "Expected raw Codex event_id not to pass through")

    let startupSession = try checkNotNil(
        HookAdapterMapper.codexHookEvent(
            from: Data(#"{"hook_event_name":"SessionStart","session_id":"contract-session","source":"startup"}"#.utf8),
            context: HookAdapterContext(agent: .codexCLI, host: "codex-cli", cwdHashSalt: "contract-salt")
        ),
        "Expected Codex startup session event to map"
    )
    let resumeSession = try checkNotNil(
        HookAdapterMapper.codexHookEvent(
            from: Data(#"{"hook_event_name":"SessionStart","session_id":"contract-session","source":"resume"}"#.utf8),
            context: HookAdapterContext(agent: .codexCLI, host: "codex-cli", cwdHashSalt: "contract-salt")
        ),
        "Expected Codex resume session event to map"
    )
    try check(startupSession.eventID != resumeSession.eventID, "Expected Codex SessionStart replay IDs to include source")
}

private func runAdapterNoOpsWhenControlEndpointIsUnavailable() throws {
    let paths = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportDirectory) }

    let startedAt = Date()
    let result = HookAdapterRunner(runtimeStore: ControlRuntimeStore(paths: paths))
        .runCodexNotify(
            payload: #"{"type":"agent-turn-complete","turn-id":"turn-contract"}"#,
            context: HookAdapterContext(agent: .codexCLI, host: "codex-cli", processID: 102)
        )
    let elapsed = Date().timeIntervalSince(startedAt)

    try check(result == HookAdapterRunResult(), "Expected unavailable endpoint to no-op cleanly")
    try check(elapsed < 0.25, "Expected no-op path to complete within 250ms")
}

private func runConfigPatchersPreserveAndRemoveOnlyOwnedBlocks() throws {
    let adapterPath = "/Applications/AgentWake.app/Contents/MacOS/AgentWakeHookAdapter"

    let claudePatcher = ClaudeCodeConfigPatcher()
    let claudeInstall = try claudePatcher.installPlan(
        currentData: fixtureData("config-patchers/claude-settings", extension: "json"),
        adapterPath: adapterPath
    )
    let claudeInstalled = String(data: claudeInstall.patchedData, encoding: .utf8) ?? ""
    try check(claudeInstalled.contains("user-security-hook"), "Expected Claude patcher to preserve user hook")
    try check(claudeInstalled.contains(ClaudeCodeConfigPatcher.manifest.ownerMarker), "Expected Claude patcher to add owner marker")
    let claudeRemoval = try claudePatcher.removalPlan(currentData: claudeInstall.patchedData)
    let claudeRemoved = String(data: claudeRemoval.patchedData, encoding: .utf8) ?? ""
    try check(claudeRemoved.contains("user-security-hook"), "Expected Claude removal to preserve user hook")
    try check(!claudeRemoved.contains(ClaudeCodeConfigPatcher.manifest.ownerMarker), "Expected Claude removal to remove owned hooks")

    let codexPatcher = CodexConfigPatcher()
    let codexInstall = try codexPatcher.installPlan(
        currentData: fixtureData("config-patchers/codex-config", extension: "toml"),
        adapterPath: adapterPath
    )
    let codexInstalled = String(data: codexInstall.patchedData, encoding: .utf8) ?? ""
    try check(codexInstalled.contains("--forward-notify"), "Expected Codex patcher to forward existing notify")
    try check(codexInstalled.contains("--mode codex-hook"), "Expected Codex patcher to install native hook command")
    try check(codexInstalled.contains("[[hooks.UserPromptSubmit]]"), "Expected Codex patcher to install turn-start hook")
    try check(codexInstalled.contains("[[hooks.Stop.hooks]]"), "Expected Codex patcher to install stop hook handler")
    try check(codexInstalled.contains("timeout = 1"), "Expected Codex native hook command to have a short timeout")
    try check(codexInstalled.contains("[profiles.work]"), "Expected Codex patcher to preserve unrelated TOML")
    let codexRemoval = try codexPatcher.removalPlan(currentData: codexInstall.patchedData)
    let codexRemoved = String(data: codexRemoval.patchedData, encoding: .utf8) ?? ""
    try codexPatcher.validate(codexRemoval.patchedData)
    try check(codexRemoved.contains(#"notify = ["/usr/local/bin/notify-user", "Codex"]"#), "Expected Codex removal to restore notify")
    try check(!codexRemoved.contains(#""Codex"][profiles.work]"#), "Expected Codex removal not to glue restored notify to next table")
    try check(!codexRemoved.contains(CodexConfigPatcher.manifest.ownerMarker), "Expected Codex removal to remove owned block")
    try check(!codexRemoved.contains("[[hooks.UserPromptSubmit]]"), "Expected Codex removal to remove owned native hooks")
    let codexReinstall = try codexPatcher.installPlan(currentData: codexInstall.patchedData, adapterPath: adapterPath)
    let codexReinstalled = String(data: codexReinstall.patchedData, encoding: .utf8) ?? ""
    try codexPatcher.validate(codexReinstall.patchedData)
    try check(!codexReinstalled.contains("\(CodexConfigPatcher.manifest.ownerMarker)[profiles.work]"), "Expected Codex reinstall not to glue owned marker to next table")
    let endMarkerLine = "# END \(CodexConfigPatcher.manifest.ownerMarker)"
    let gluedEndMarker = codexInstalled
        .replacingOccurrences(of: "\(endMarkerLine)\n\n[profiles.work]", with: "\(endMarkerLine)[profiles.work]")
        .replacingOccurrences(of: "\(endMarkerLine)\n[profiles.work]", with: "\(endMarkerLine)[profiles.work]")
    try check(gluedEndMarker != codexInstalled, "Expected test fixture to contain a glueable owned end marker")
    let recoveredInstall = try codexPatcher.installPlan(currentData: Data(gluedEndMarker.utf8), adapterPath: adapterPath)
    let recoveredInstalled = String(data: recoveredInstall.patchedData, encoding: .utf8) ?? ""
    try codexPatcher.validate(recoveredInstall.patchedData)
    try check(recoveredInstalled.contains("[profiles.work]"), "Expected Codex reinstall to preserve table glued to old end marker")
    try check(!recoveredInstalled.contains("\(CodexConfigPatcher.manifest.ownerMarker)[profiles.work]"), "Expected Codex reinstall to repair glued old end marker")

    let codexWithUserHooks = """
    [hooks.state."/tmp/user-hook:pre_tool_use:0:0"]
    enabled = true

    [[hooks.PreToolUse]]
    matcher = "^Bash$"

    [[hooks.PreToolUse.hooks]]
    type = "command"
    command = "/usr/local/bin/user-codex-hook"
    """
    let userHookInstall = try codexPatcher.installPlan(currentData: Data(codexWithUserHooks.utf8), adapterPath: adapterPath)
    let userHookInstalled = String(data: userHookInstall.patchedData, encoding: .utf8) ?? ""
    try check(userHookInstalled.contains("/usr/local/bin/user-codex-hook"), "Expected Codex patcher to preserve user hook command")
    try check(userHookInstalled.contains(#"[hooks.state."/tmp/user-hook:pre_tool_use:0:0"]"#), "Expected Codex patcher to preserve user hook state table")
    try check(userHookInstalled.contains("[[hooks.PreToolUse]]"), "Expected Codex patcher to preserve user hook table")
    let userHookRemoval = try codexPatcher.removalPlan(currentData: userHookInstall.patchedData)
    let userHookRemoved = String(data: userHookRemoval.patchedData, encoding: .utf8) ?? ""
    try codexPatcher.validate(userHookRemoval.patchedData)
    try check(userHookRemoved.contains("/usr/local/bin/user-codex-hook"), "Expected Codex removal to preserve user hook command")
    try check(userHookRemoved.contains(#"[hooks.state."/tmp/user-hook:pre_tool_use:0:0"]"#), "Expected Codex removal to preserve user hook state table")
    try check(!userHookRemoved.contains(CodexConfigPatcher.manifest.ownerMarker), "Expected Codex removal to remove only owned native hook block")
    let multilineCodex = """
    model = "gpt-5.5"
    notify = [
      '/usr/local/bin/notify-user', # comment with ] should not close the array
      'Codex',
    ]

    [profiles.work]
    model = "gpt-5.4"
    """
    let multilineInstall = try codexPatcher.installPlan(currentData: Data(multilineCodex.utf8), adapterPath: adapterPath)
    let multilineInstalled = String(data: multilineInstall.patchedData, encoding: .utf8) ?? ""
    try check(multilineInstalled.contains("--forward-notify"), "Expected multiline single-quoted notify to be forwarded")
    let multilineRemoval = try codexPatcher.removalPlan(currentData: multilineInstall.patchedData)
    let multilineRemoved = String(data: multilineRemoval.patchedData, encoding: .utf8) ?? ""
    try check(multilineRemoved.contains("notify = ["), "Expected multiline notify assignment to be restored")
    try check(multilineRemoved.contains("'/usr/local/bin/notify-user'"), "Expected single-quoted notify command to be restored")

    let markerLookalike = """
    # BEGIN \(CodexConfigPatcher.manifest.ownerMarker) but user-owned
    notify = ["/usr/local/bin/notify-user"]
    # END \(CodexConfigPatcher.manifest.ownerMarker) but user-owned
    """
    let lookalikeRemoval = try codexPatcher.removalPlan(currentData: Data(markerLookalike.utf8))
    let lookalikeRemoved = String(data: lookalikeRemoval.patchedData, encoding: .utf8) ?? ""
    try check(lookalikeRemoved.contains("but user-owned"), "Expected marker lookalikes not to be removed")

    // Defense: when an external tool has written a top-level `notify =` line on
    // top of our owned block, uninstall must NOT restore the recorded previous
    // notify — emitting it would create a duplicate `notify =` key. Reproduces
    // the real-world bug where the Codex Computer Use plugin wrote its own
    // notify line over an AgentWake-owned block, then uninstall left two
    // notify keys in the file.
    let orphanNotifyLine = #"notify = ["/Applications/External/Foo", "turn-ended"]"#
    let installedWithOrphan = orphanNotifyLine + "\n" + codexInstalled
    let orphanRemoval = try codexPatcher.removalPlan(currentData: Data(installedWithOrphan.utf8))
    let orphanRemoved = String(data: orphanRemoval.patchedData, encoding: .utf8) ?? ""
    try codexPatcher.validate(orphanRemoval.patchedData)
    try check(orphanRemoved.contains("/Applications/External/Foo"), "Expected external orphan notify to be preserved when our block is removed")
    try check(!orphanRemoved.contains(CodexConfigPatcher.manifest.ownerMarker), "Expected owned block to be removed when orphan exists")
    try check(!orphanRemoved.contains("notify-user"), "Expected recorded previous notify NOT to be restored when external orphan is present (would create duplicate key)")
    try check(topLevelNotifyOccurrences(in: orphanRemoved) == 1, "Expected exactly one top-level notify after uninstall with external orphan present")

    // Regression: when there is NO external orphan, the recorded previous
    // notify must still be restored (existing behavior).
    let cleanRemoval = try codexPatcher.removalPlan(currentData: codexInstall.patchedData)
    let cleanRemoved = String(data: cleanRemoval.patchedData, encoding: .utf8) ?? ""
    try check(cleanRemoved.contains(#"notify = ["/usr/local/bin/notify-user", "Codex"]"#), "Expected clean uninstall (no orphan) to restore recorded previous notify")
    try check(topLevelNotifyOccurrences(in: cleanRemoved) == 1, "Expected exactly one top-level notify after clean uninstall")

    // Defense: validate rejects any output that contains duplicate top-level
    // keys, so the patcher refuses to write a corrupt TOML to disk.
    let duplicateNotify = """
    model = "gpt-5.5"
    notify = ["/usr/local/bin/notify-user", "Codex"]

    notify = ["/Applications/External/Foo", "turn-ended"]

    [profiles.work]
    model = "gpt-5.4"
    """
    var threwDuplicateNotify = false
    do {
        try codexPatcher.validate(Data(duplicateNotify.utf8))
    } catch IntegrationPatcherError.invalidTOML(let message) where message.contains("duplicate top-level key") {
        threwDuplicateNotify = true
    }
    try check(threwDuplicateNotify, "Expected validate to reject duplicate top-level notify keys")

    // Same-named key inside a sub-table is NOT a duplicate (different scope).
    let scopedNotify = """
    model = "gpt-5.5"
    notify = ["/usr/local/bin/notify-user", "Codex"]

    [profiles.work]
    notify = ["other"]
    """
    try codexPatcher.validate(Data(scopedNotify.utf8))

    // Inline tables with `=` inside the value must not confuse the duplicate-key
    // scanner — only the outer key counts.
    let inlineTable = """
    profile = { name = "foo", value = 1 }
    notify = ["x"]
    """
    try codexPatcher.validate(Data(inlineTable.utf8))

    // A multi-line `notify = [...]` continuation line that contains `=` inside a
    // quoted element must not be misread as a new top-level key.
    let multilineNotifyWithEquals = """
    notify = [
      "/usr/local/bin/notify-user",
      "--option=x=y",
    ]
    """
    try codexPatcher.validate(Data(multilineNotifyWithEquals.utf8))

    // Dotted top-level keys like `apple.color = ...` and `apple.taste = ...` are
    // distinct keys and must not be flagged as duplicates.
    let dottedKeys = """
    apple.color = "red"
    apple.taste = "tart"
    notify = ["x"]
    """
    try codexPatcher.validate(Data(dottedKeys.utf8))
}

private func topLevelNotifyOccurrences(in content: String) -> Int {
    var count = 0
    var inTopLevel = true
    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            inTopLevel = false
            continue
        }
        guard inTopLevel else { continue }
        let collapsed = trimmed.filter { !$0.isWhitespace }
        if collapsed.hasPrefix("notify=") {
            count += 1
        }
    }
    return count
}

private func fixtureData(_ name: String, extension ext: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
        throw ContractFailure("Missing fixture: \(name).\(ext)")
    }

    return try Data(contentsOf: url)
}

private func temporaryPaths() throws -> AgentWakePaths {
    let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("cs-contract-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return AgentWakePaths(applicationSupportDirectory: url)
}

private func checkNotNil<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw ContractFailure(message)
    }

    return value
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw ContractFailure(message)
    }
}

private struct ContractFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
