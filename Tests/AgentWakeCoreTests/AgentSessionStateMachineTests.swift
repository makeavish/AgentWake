import Foundation

#if canImport(Testing)
import Testing
@testable import AgentWakeCore

struct AgentSessionStateMachineTests {
    @Test func detectorMatchesBuiltInAgentsWithPathHashes() throws {
        try runDetectorMatchesBuiltInAgentsWithPathHashes()
    }

    @Test func processIdentityDedupesAndSeparatesPIDReuse() throws {
        try runProcessIdentityDedupesAndSeparatesPIDReuse()
    }

    @Test func pathLookupVolatilityDoesNotSplitSessions() throws {
        try runPathLookupVolatilityDoesNotSplitSessions()
    }

    @Test func executablePathHashParticipatesInVerifiedIdentity() throws {
        try runExecutablePathHashParticipatesInVerifiedIdentity()
    }

    @Test func agentMonitorPollsSnapshotsEveryTwoSecondsByDefault() throws {
        try runAgentMonitorPollsSnapshotsEveryTwoSecondsByDefault()
    }

    @Test func processOnlyDetectionsRemainDiagnosticUntilIntegrated() throws {
        try runProcessOnlyDetectionsRemainDiagnosticUntilIntegrated()
    }

    @Test func sessionOverviewCombinesAgentStateBuckets() throws {
        try runSessionOverviewCombinesAgentStateBuckets()
    }

    @Test func processOnlyDetectionDoesNotProtectWithoutIntegration() throws {
        try runProcessOnlyDetectionDoesNotProtectWithoutIntegration()
    }

    @Test func sessionStartDoesNotProtectDetectedProcess() throws {
        try runSessionStartDoesNotProtectDetectedProcess()
    }

    @Test func agentMonitorStartUsesTimerCadence() throws {
        try runAgentMonitorStartUsesTimerCadence()
    }

    @Test func transitionMatrixCoversActivityTurnCompletionAndFinish() throws {
        try runTransitionMatrixCoversActivityTurnCompletionAndFinish()
    }

    @Test func cpuDiagnosticsDoNotResetActivityOrGrace() throws {
        try runCPUDiagnosticsDoNotResetActivityOrGrace()
    }

    @Test func aggregateHoldRequiresEverySessionToFinishOrExpire() throws {
        try runAggregateHoldRequiresEverySessionToFinishOrExpire()
    }

    @Test func remainingTransitionRowsAreExecutable() throws {
        try runRemainingTransitionRowsAreExecutable()
    }

    @Test func trustedEventsAreMonotonic() throws {
        try runTrustedEventsAreMonotonic()
    }

    @Test func outOfOrderHookEventsAreIgnored() throws {
        try runOutOfOrderHookEventsAreIgnored()
    }

    @Test func manualOverridePrecedenceAndPersistence() throws {
        try runManualOverridePrecedenceAndPersistence()
    }
}

#elseif canImport(XCTest)
import XCTest
@testable import AgentWakeCore

final class AgentSessionStateMachineTests: XCTestCase {
    func testDetectorMatchesBuiltInAgentsWithPathHashes() throws {
        try runDetectorMatchesBuiltInAgentsWithPathHashes()
    }

    func testProcessIdentityDedupesAndSeparatesPIDReuse() throws {
        try runProcessIdentityDedupesAndSeparatesPIDReuse()
    }

    func testPathLookupVolatilityDoesNotSplitSessions() throws {
        try runPathLookupVolatilityDoesNotSplitSessions()
    }

    func testExecutablePathHashParticipatesInVerifiedIdentity() throws {
        try runExecutablePathHashParticipatesInVerifiedIdentity()
    }

    func testAgentMonitorPollsSnapshotsEveryTwoSecondsByDefault() throws {
        try runAgentMonitorPollsSnapshotsEveryTwoSecondsByDefault()
    }

    func testProcessOnlyStartupDetectionHoldsNewestSessionProvisionally() throws {
        try runProcessOnlyDetectionsRemainDiagnosticUntilIntegrated()
    }

    func testSessionOverviewCombinesAgentStateBuckets() throws {
        try runSessionOverviewCombinesAgentStateBuckets()
    }

    func testReleaseNowSuppressesProcessOnlyProvisionalRehold() throws {
        try runProcessOnlyDetectionDoesNotProtectWithoutIntegration()
    }

    func testSessionStartDoesNotProtectDetectedProcess() throws {
        try runSessionStartDoesNotProtectDetectedProcess()
    }

    func testAgentMonitorStartUsesTimerCadence() throws {
        try runAgentMonitorStartUsesTimerCadence()
    }

    func testTransitionMatrixCoversActivityTurnCompletionAndFinish() throws {
        try runTransitionMatrixCoversActivityTurnCompletionAndFinish()
    }

    func testCPUDiagnosticsDoNotResetActivityOrGrace() throws {
        try runCPUDiagnosticsDoNotResetActivityOrGrace()
    }

    func testAggregateHoldRequiresEverySessionToFinishOrExpire() throws {
        try runAggregateHoldRequiresEverySessionToFinishOrExpire()
    }

    func testRemainingTransitionRowsAreExecutable() throws {
        try runRemainingTransitionRowsAreExecutable()
    }

    func testTrustedEventsAreMonotonic() throws {
        try runTrustedEventsAreMonotonic()
    }

    func testOutOfOrderHookEventsAreIgnored() throws {
        try runOutOfOrderHookEventsAreIgnored()
    }

    func testManualOverridePrecedenceAndPersistence() throws {
        try runManualOverridePrecedenceAndPersistence()
    }
}

#else
#error("This toolchain does not provide Testing or XCTest. Run `swift run AgentWakeCoreChecks` for portable checks.")
#endif

#if canImport(Testing) || canImport(XCTest)
private let baseline = Date(timeIntervalSince1970: 1_000)

private func runDetectorMatchesBuiltInAgentsWithPathHashes() throws {
    let detector = AgentProcessDetector(settings: AgentWakeSettings())
    let observations = detector.observations(
        in: [
            ProcessSnapshot(
                pid: 11,
                processName: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                processStartTime: baseline
            ),
            ProcessSnapshot(
                pid: 12,
                processName: "claude-code",
                executablePath: "/usr/local/bin/claude-code",
                processStartTime: baseline
            ),
            ProcessSnapshot(
                pid: 13,
                processName: "codex",
                executablePath: "/opt/homebrew/bin/codex",
                processStartTime: baseline
            ),
            ProcessSnapshot(
                pid: 15,
                processName: "codex",
                executablePath: nil,
                processStartTime: baseline
            ),
            ProcessSnapshot(
                pid: 16,
                processName: "codex",
                executablePath: "/opt/homebrew/Caskroom/codex/codex-aarch64-apple-darwin",
                processStartTime: baseline
            ),
            ProcessSnapshot(
                pid: 14,
                processName: "not-codex",
                executablePath: "/usr/bin/not-codex",
                processStartTime: baseline
            )
        ]
    )

    try check(
        observations.map(\.agent) == [.claudeCode, .claudeCode, .codexCLI, .codexCLI, .codexCLI],
        "Expected V1 built-in agent matches"
    )
    try check(observations.allSatisfy { $0.key.executablePathHash != nil }, "Expected executable path hashes when paths are available")
    try check(
        observations[0].key.executablePathHash == StablePathHash.sha256("/opt/homebrew/bin/claude"),
        "Expected real executable path to drive path hash"
    )
    try check(
        observations[0].key.executablePathHash != "/opt/homebrew/bin/claude",
        "Expected path hash to avoid retaining the raw executable path"
    )
    try check(observations[3].key.executablePathHashIsVerified == false, "Expected missing paths to be marked unverified")
    try check(observations[4].key.executablePathHashIsVerified, "Expected resolved paths to be marked verified")
}

private func runProcessIdentityDedupesAndSeparatesPIDReuse() throws {
    let machine = AgentSessionStateMachine()
    machine.applyProcessObservations([observation(pid: 42, start: baseline)], at: baseline)
    let firstSession = try checkNotNil(machine.sessions.first, "Expected initial session")

    machine.applyProcessObservations(
        [observation(pid: 42, start: baseline, cpuPercent: 99)],
        at: baseline.addingTimeInterval(30)
    )
    try check(machine.sessions.count == 1, "Expected matching pid/start/path to dedupe")
    try check(machine.sessions[0].id == firstSession.id, "Expected repeated process observation to keep session identity")
    try check(machine.sessions[0].lastActivityAt == baseline, "Expected mere process presence and CPU changes not to reset activity")
    try check(machine.sessions[0].diagnosticCPUPercent == 99, "Expected CPU to be retained only as diagnostics")

    let restartedAt = baseline.addingTimeInterval(60)
    machine.applyProcessObservations([observation(pid: 42, start: restartedAt)], at: restartedAt)

    try check(machine.sessions.count == 2, "Expected PID reuse with a new start time to create a new session")
    try check(machine.sessions.contains { $0.id == firstSession.id && $0.state == .finished }, "Expected reused PID to finish the old session")
    try check(machine.sessions.contains { $0.id != firstSession.id && $0.state == .active }, "Expected reused PID to create an active session")
}

private func runPathLookupVolatilityDoesNotSplitSessions() throws {
    let machine = AgentSessionStateMachine()

    machine.applyProcessObservations(
        [observationWithMissingPath(pid: 43, start: baseline, processName: "claude", agent: .claudeCode)],
        at: baseline
    )
    let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected fallback process session")
    machine.applyTrustedEvent(.turnFinished, to: sessionID, at: baseline.addingTimeInterval(10))
    try check(machine.sessions.first?.state == .finished, "Expected turn completion to finish the process-backed turn")
    try check(machine.sessions.first?.standingByExpiresAt == nil, "Expected turn completion not to keep a grace hold")

    machine.applyProcessObservations(
        [observation(pid: 43, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode)],
        at: baseline.addingTimeInterval(20)
    )

    try check(machine.sessions.count == 2, "Expected live process polling after turn completion to create a diagnostic process session")
    try check(machine.sessions[0].id == sessionID, "Expected path hash upgrade to preserve session identity")
    try check(machine.sessions[0].state == .finished, "Expected path hash upgrade not to reactivate the finished turn")
    try check(machine.sessions[1].source == .processScan, "Expected replacement session to stay process-detected only")
    try check(machine.sessions[1].key.executablePathHash == StablePathHash.sha256("/opt/homebrew/bin/claude"), "Expected path hash to be recorded on the diagnostic process session")
    try check(machine.sessions[1].key.executablePathHashIsVerified, "Expected diagnostic path hash to be marked verified")
}

private func runExecutablePathHashParticipatesInVerifiedIdentity() throws {
    let machine = AgentSessionStateMachine()
    machine.applyProcessObservations(
        [observation(pid: 44, start: baseline, path: "/opt/homebrew/bin/codex")],
        at: baseline
    )
    let firstSessionID = try checkNotNil(machine.sessions.first?.id, "Expected first verified session")

    machine.applyProcessObservations(
        [observation(pid: 44, start: baseline, path: "/tmp/codex")],
        at: baseline.addingTimeInterval(10)
    )

    try check(machine.sessions.count == 2, "Expected same pid/start with a different verified path to create a new identity")
    try check(machine.sessions.contains { $0.id == firstSessionID && $0.state == .finished }, "Expected old verified-path session to be closed")
    try check(machine.sessions.contains { $0.id != firstSessionID && $0.state == .active }, "Expected new verified-path identity to be active")
}

private func runAgentMonitorPollsSnapshotsEveryTwoSecondsByDefault() throws {
    let monitor = AgentMonitor(
        snapshotProvider: StaticSnapshotProvider(
            snapshotsToReturn: [
                ProcessSnapshot(
                    pid: 24,
                    processName: "codex",
                    executablePath: "/opt/homebrew/bin/codex",
                    processStartTime: baseline
                )
            ]
        ),
        settingsProvider: { AgentWakeSettings() },
        now: { baseline }
    )

    try check(monitor.pollInterval == 2, "Expected default process polling interval to be two seconds")
    monitor.poll()
    try check(monitor.sessions.count == 1, "Expected monitor poll to normalize snapshots into sessions")
    try check(monitor.sessions.first?.agent == .codexCLI, "Expected monitor to detect Codex CLI")
}

private func runProcessOnlyDetectionsRemainDiagnosticUntilIntegrated() throws {
    var currentDate = Date(timeIntervalSince1970: 2_000)
    let monitor = AgentMonitor(
        snapshotProvider: StaticSnapshotProvider(
            snapshotsToReturn: [
                ProcessSnapshot(
                    pid: 31,
                    processName: "claude",
                    executablePath: "/opt/homebrew/bin/claude",
                    processStartTime: currentDate.addingTimeInterval(-300)
                ),
                ProcessSnapshot(
                    pid: 32,
                    processName: "codex",
                    executablePath: "/opt/homebrew/bin/codex",
                    processStartTime: currentDate.addingTimeInterval(-60)
                ),
                ProcessSnapshot(
                    pid: 33,
                    processName: "claude",
                    executablePath: "/usr/local/bin/claude-code",
                    processStartTime: currentDate.addingTimeInterval(-180)
                )
            ]
        ),
        settingsProvider: { AgentWakeSettings(defaultGraceSeconds: 900) },
        now: { currentDate }
    )

    monitor.poll()
    try check(
        monitor.sessionSummaryMessage() == "3 sessions detected",
        "Expected process-only detections to remain diagnostic until hook evidence arrives: \(monitor.sessionSummaryMessage())"
    )
    try check(
        monitor.sessionOverviewMessage().contains("Codex CLI: detected"),
        "Expected settings overview to hide process diagnostics: \(monitor.sessionOverviewMessage())"
    )
    try check(
        monitor.sessionListMessage().contains("Codex CLI: detected source=processScan pid=32"),
        "Expected process-only detection to be labeled detected: \(monitor.sessionListMessage())"
    )

    currentDate = currentDate.addingTimeInterval(901)
    try check(
        monitor.sessionSummaryMessage() == "3 sessions detected",
        "Expected process-only detections to stay diagnostic without hook evidence: \(monitor.sessionSummaryMessage())"
    )
}

private func runSessionOverviewCombinesAgentStateBuckets() throws {
    let currentDate = Date(timeIntervalSince1970: 2_100)
    let firstProcessStart = currentDate.addingTimeInterval(-30)
    let monitor = AgentMonitor(
        snapshotProvider: StaticSnapshotProvider(
            snapshotsToReturn: [
                ProcessSnapshot(
                    pid: 41,
                    processName: "claude",
                    executablePath: "/opt/homebrew/bin/claude",
                    processStartTime: firstProcessStart
                ),
                ProcessSnapshot(
                    pid: 42,
                    processName: "claude",
                    executablePath: "/opt/homebrew/bin/claude",
                    processStartTime: currentDate.addingTimeInterval(-60)
                ),
                ProcessSnapshot(
                    pid: 43,
                    processName: "claude",
                    executablePath: "/usr/local/bin/claude-code",
                    processStartTime: currentDate.addingTimeInterval(-90)
                )
            ]
        ),
        settingsProvider: { AgentWakeSettings(defaultGraceSeconds: 900) },
        now: { currentDate }
    )

    monitor.poll()
    monitor.applyIntegrationEvent(
        hookEvent(
            .toolStarted,
            integrationSessionId: "claude-active",
            pid: 41,
            processStartTime: firstProcessStart,
            agent: .claudeCode
        ),
        at: currentDate.addingTimeInterval(1)
    )

    let overview = monitor.sessionOverviewMessage()
    try check(
        overview == "Claude Code: keeping awake, 2 detected",
        "Expected one Claude Code row with combined states, got: \(overview)"
    )
    try check(
        overview.components(separatedBy: "Claude Code:").count == 2,
        "Expected Claude Code to appear only once, got: \(overview)"
    )
}

private func runProcessOnlyDetectionDoesNotProtectWithoutIntegration() throws {
    let machine = AgentSessionStateMachine(graceInterval: 900)
    let processObservation = observation(
        pid: 34,
        start: baseline.addingTimeInterval(-30),
        path: "/opt/homebrew/bin/claude",
        agent: .claudeCode
    )

    machine.applyProcessObservations([processObservation], at: baseline)
    try check(machine.sessions.first?.id != nil, "Expected process-backed session")
    try check(!machine.aggregateHoldState(at: baseline).shouldHold, "Expected process-only detection not to protect")

    machine.applyProcessObservations([processObservation], at: baseline.addingTimeInterval(2))
    try check(
        !machine.aggregateHoldState(at: baseline.addingTimeInterval(2)).shouldHold,
        "Expected process-only session not to protect on the next poll"
    )

    let protectedCount = machine.protectDetectedProcessSessions(at: baseline.addingTimeInterval(3))
    try check(protectedCount == 1, "Expected manual action to protect one detected process")
    try check(
        machine.aggregateHoldState(at: baseline.addingTimeInterval(3)).shouldHold,
        "Expected manual protection to hold while the process remains open"
    )
    try check(
        machine.sessions.first?.lastEvent?.kind == .manualProtectDetected,
        "Expected manual protection event to be recorded"
    )

    machine.applyProcessObservations([], at: baseline.addingTimeInterval(4))
    try check(
        !machine.aggregateHoldState(at: baseline.addingTimeInterval(4)).shouldHold,
        "Expected manually protected detected session to release when the process exits"
    )
}

private func runSessionStartDoesNotProtectDetectedProcess() throws {
    let machine = AgentSessionStateMachine(graceInterval: 900, agentResumeIdleTimeout: 30)
    let processStart = baseline.addingTimeInterval(-120)
    let processObservation = observation(
        pid: 35,
        start: processStart,
        path: "/opt/homebrew/bin/claude",
        agent: .claudeCode
    )

    machine.applyProcessObservations([processObservation], at: baseline)
    let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected process-backed Claude session")
    machine.applyIntegrationEvent(
        hookEvent(
            .sessionStarted,
            integrationSessionId: "claude-resumed-session",
            pid: 35,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline.addingTimeInterval(1)
    )

    try check(machine.sessions.first?.id == sessionID, "Expected SessionStart not to create a replacement session")
    try check(
        machine.sessions.first?.lastEvent?.kind == .matchingProcessStarted,
        "Expected SessionStart/resume not to become protecting activity"
    )
    try check(
        !machine.aggregateHoldState(at: baseline.addingTimeInterval(1)).shouldHold,
        "Expected bare Claude SessionStart/resume not to keep the Mac awake"
    )
    try check(
        machine.sessions.first?.key.integrationSessionId == nil,
        "Expected bare SessionStart/resume not to attach confirmed integration evidence"
    )

    machine.applyIntegrationEvent(
        hookEvent(
            .turnStarted,
            integrationSessionId: "claude-resumed-session",
            pid: 35,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline.addingTimeInterval(2)
    )

    try check(
        machine.aggregateHoldState(at: baseline.addingTimeInterval(2)).shouldHold,
        "Expected Claude UserPromptSubmit to keep the Mac awake for real activity"
    )
    try check(
        machine.sessions.first?.key.integrationSessionId == "claude-resumed-session",
        "Expected real turn activity to attach integration evidence"
    )

    machine.applyProcessObservations([processObservation], at: baseline.addingTimeInterval(33))
    try check(
        !machine.aggregateHoldState(at: baseline.addingTimeInterval(33)).shouldHold,
        "Expected stale Claude turn-start activity to release if no tool or stop event follows"
    )
    try check(
        machine.sessions.contains { $0.lastEvent?.kind == .staleActivityExpired },
        "Expected stale Claude turn-start activity to record an expiry event"
    )
    try check(
        machine.sessions.contains {
            $0.source == .processScan && $0.state != .finished && !$0.hasIntegratedEvidence
        },
        "Expected the still-open Claude process to remain visible only as a detected process"
    )
}

private func runAgentMonitorStartUsesTimerCadence() throws {
    let provider = CountingSnapshotProvider(
        snapshotsToReturn: [
            ProcessSnapshot(
                pid: 25,
                processName: "codex",
                executablePath: "/opt/homebrew/bin/codex",
                processStartTime: baseline
            )
        ]
    )
    let monitor = AgentMonitor(
        snapshotProvider: provider,
        settingsProvider: { AgentWakeSettings() },
        pollInterval: 0.01,
        now: { baseline }
    )

    monitor.start()
    try check(monitor.scheduledPollInterval == 0.01, "Expected start() to schedule the configured poll cadence")
    try check(provider.callCount == 1, "Expected start() to perform an immediate poll")
    monitor.stop()
    try check(monitor.scheduledPollInterval == nil, "Expected stop() to cancel the scheduled poll")
}

private func runTransitionMatrixCoversActivityTurnCompletionAndFinish() throws {
    let machine = AgentSessionStateMachine(graceInterval: 900)
    machine.applyProcessObservations(
        [observation(pid: 50, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode)],
        at: baseline
    )
    let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected active process-backed session")

    try check(machine.sessions[0].state == .active, "Expected matching process start to create an active session")
    try check(!machine.aggregateHoldState(at: baseline).shouldHold, "Expected process-only session not to protect")
    try check(
        !machine.aggregateHoldState(at: baseline.addingTimeInterval(901)).shouldHold,
        "Expected process-only session to remain diagnostic without integration evidence"
    )
    machine.applyIntegrationEvent(
        HookAdapterEvent(
            agent: .claudeCode,
            host: "claude-code",
            event: .toolStarted,
            pid: 50,
            processStartTime: baseline,
            integrationSessionId: "claude-session-50"
        ),
        at: baseline.addingTimeInterval(1)
    )
    try check(machine.aggregateHoldState(at: baseline.addingTimeInterval(1)).shouldHold, "Expected integration-backed session to hold")

    let turnFinishedAt = baseline.addingTimeInterval(10)
    machine.applyTrustedEvent(.turnFinished, to: sessionID, at: turnFinishedAt)
    try check(machine.sessions[0].state == .finished, "Expected turn finish to release the protected turn")
    try check(machine.sessions[0].standingByExpiresAt == nil, "Expected turn finish not to keep a grace hold")
    try check(!machine.aggregateHoldState(at: turnFinishedAt.addingTimeInterval(1)).shouldHold, "Expected completed turn not to hold")

    let resumedAt = baseline.addingTimeInterval(20)
    machine.applyTrustedEvent(.agentResumed, to: sessionID, at: resumedAt)
    try check(machine.sessions[0].state == .finished, "Expected later activity on the finished turn not to reactivate it")

    let secondTurnFinishedAt = baseline.addingTimeInterval(30)
    machine.applyTrustedEvent(.turnFinished, to: sessionID, at: secondTurnFinishedAt)
    machine.applyTrustedEvent(.keepHolding, to: sessionID, at: baseline.addingTimeInterval(40))
    try check(machine.sessions[0].state == .finished, "Expected keepHolding not to extend a completed turn")

    machine.refreshExpirations(at: secondTurnFinishedAt.addingTimeInterval(1_801))
    try check(machine.sessions[0].state == .finished, "Expected completed turn to remain finished")
    try check(!machine.aggregateHoldState(at: secondTurnFinishedAt.addingTimeInterval(1_801)).shouldHold, "Expected expired session not to hold")
}

private func runCPUDiagnosticsDoNotResetActivityOrGrace() throws {
    let machine = AgentSessionStateMachine(graceInterval: 900)
    machine.applyProcessObservations(
        [observation(pid: 60, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode, cpuPercent: 1)],
        at: baseline
    )
    let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected active session")

    machine.applyProcessObservations(
        [observation(pid: 60, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode, cpuPercent: 88)],
        at: baseline.addingTimeInterval(120)
    )
    try check(machine.sessions[0].lastActivityAt == baseline, "Expected CPU changes not to reset active timestamp")

    let turnFinishedAt = baseline.addingTimeInterval(180)
    machine.applyTrustedEvent(.turnFinished, to: sessionID, at: turnFinishedAt)
    try check(machine.sessions[0].state == .finished, "Expected turn completion to finish the protected turn")
    try check(machine.sessions[0].standingByExpiresAt == nil, "Expected turn completion not to keep a grace hold")

    machine.applyProcessObservations(
        [observation(pid: 60, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode, cpuPercent: 0)],
        at: baseline.addingTimeInterval(240)
    )
    try check(machine.sessions[0].state == .finished, "Expected process presence not to reactivate the finished turn")
    try check(
        machine.sessions.contains { $0.source == .processScan && $0.state == .active && !$0.hasIntegratedEvidence },
        "Expected live process presence to remain diagnostic only"
    )
}

private func runAggregateHoldRequiresEverySessionToFinishOrExpire() throws {
    let machine = AgentSessionStateMachine(graceInterval: 900)
    machine.applyProcessObservations(
        [
            observation(pid: 70, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode),
            observation(pid: 71, start: baseline, path: "/opt/homebrew/bin/codex", agent: .codexCLI)
        ],
        at: baseline
    )

    let claudeID = try checkNotNil(machine.sessions.first(where: { $0.agent == .claudeCode })?.id, "Expected Claude session")
    let codexID = try checkNotNil(machine.sessions.first(where: { $0.agent == .codexCLI })?.id, "Expected Codex session")
    machine.applyIntegrationEvent(
        HookAdapterEvent(
            agent: .claudeCode,
            host: "claude-code",
            event: .toolStarted,
            pid: 70,
            processStartTime: baseline,
            integrationSessionId: "claude-session"
        ),
        at: baseline.addingTimeInterval(1)
    )
    machine.applyIntegrationEvent(
        HookAdapterEvent(
            agent: .codexCLI,
            host: "codex-cli",
            event: .toolStarted,
            pid: 71,
            processStartTime: baseline,
            integrationSessionId: "codex-session"
        ),
        at: baseline.addingTimeInterval(2)
    )

    machine.applyTrustedEvent(.turnFinished, to: claudeID, at: baseline.addingTimeInterval(10))
    machine.applyTrustedEvent(.sessionFinished, to: codexID, at: baseline.addingTimeInterval(20))
    try check(!machine.aggregateHoldState(at: baseline.addingTimeInterval(30)).shouldHold, "Expected aggregate hold to release when all active turns finish")
}

private func runRemainingTransitionRowsAreExecutable() throws {
    let machine = AgentSessionStateMachine(graceInterval: 900)
    machine.applyProcessObservations(
        [
            observation(pid: 80, start: baseline, path: "/opt/homebrew/bin/claude", agent: .claudeCode),
            observation(pid: 81, start: baseline, path: "/opt/homebrew/bin/codex", agent: .codexCLI)
        ],
        at: baseline
    )
    let claudeID = try checkNotNil(machine.sessions.first(where: { $0.agent == .claudeCode })?.id, "Expected Claude session")
    let codexID = try checkNotNil(machine.sessions.first(where: { $0.agent == .codexCLI })?.id, "Expected Codex session")
    machine.applyIntegrationEvent(
        HookAdapterEvent(
            agent: .claudeCode,
            host: "claude-code",
            event: .toolStarted,
            pid: 80,
            processStartTime: baseline,
            integrationSessionId: "claude-session"
        ),
        at: baseline.addingTimeInterval(1)
    )
    machine.applyIntegrationEvent(
        HookAdapterEvent(
            agent: .codexCLI,
            host: "codex-cli",
            event: .toolStarted,
            pid: 81,
            processStartTime: baseline,
            integrationSessionId: "codex-session"
        ),
        at: baseline.addingTimeInterval(2)
    )

    machine.applyTrustedEvent(.releaseNow, to: claudeID, at: baseline.addingTimeInterval(10))
    try check(machine.sessions.first(where: { $0.id == claudeID })?.state == .finished, "Expected releaseNow to release the selected session")
    try check(machine.aggregateHoldState(at: baseline.addingTimeInterval(11)).shouldHold, "Expected other active sessions to keep aggregate hold active")

    machine.pauseAll(until: baseline.addingTimeInterval(20))
    try check(machine.aggregateHoldState(at: baseline.addingTimeInterval(12)).isPaused, "Expected pauseAll to suppress aggregate hold")
    try check(!machine.aggregateHoldState(at: baseline.addingTimeInterval(12)).shouldHold, "Expected pauseAll to release assertions")
    try check(machine.aggregateHoldState(at: baseline.addingTimeInterval(21)).shouldHold, "Expected pause expiry to restore remaining held sessions")

    machine.setSafetyCutoffActive(true)
    try check(machine.aggregateHoldState(at: baseline.addingTimeInterval(22)).isSafetyCutoffActive, "Expected safety cutoff to be represented")
    try check(!machine.aggregateHoldState(at: baseline.addingTimeInterval(22)).shouldHold, "Expected safety cutoff to suppress aggregate hold")
    machine.setSafetyCutoffActive(false)

    machine.applyTrustedEvent(.sessionFinished, to: codexID, at: baseline.addingTimeInterval(30))
    try check(!machine.aggregateHoldState(at: baseline.addingTimeInterval(31)).shouldHold, "Expected sessionFinished to release when no held sessions remain")

    machine.applyProcessObservations([observation(pid: 82, start: baseline.addingTimeInterval(40))], at: baseline.addingTimeInterval(40))
    let processGoneID = try checkNotNil(machine.sessions.first(where: { $0.key.pid == 82 })?.id, "Expected process-backed session")
    machine.applyProcessObservations([], at: baseline.addingTimeInterval(50))
    let processGoneSession = try checkNotNil(machine.sessions.first(where: { $0.id == processGoneID }), "Expected process-backed session to remain visible")
    try check(processGoneSession.state == .finished, "Expected missing process poll to finish the session")
    try check(processGoneSession.processExitedAt == baseline.addingTimeInterval(50), "Expected process exit time to be recorded")
}

private func runTrustedEventsAreMonotonic() throws {
    let machine = AgentSessionStateMachine(graceInterval: 900)
    machine.applyProcessObservations([observation(pid: 90, start: baseline)], at: baseline)
    let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected session")

    machine.applyTrustedEvent(.agentResumed, to: sessionID, at: baseline.addingTimeInterval(20))
    machine.applyTrustedEvent(.turnFinished, to: sessionID, at: baseline.addingTimeInterval(10))
    try check(machine.sessions[0].state == .active, "Expected stale turnFinished not to move active session backward")

    machine.applyTrustedEvent(.turnFinished, to: sessionID, at: baseline.addingTimeInterval(30))
    machine.applyTrustedEvent(.keepHolding, to: sessionID, at: baseline.addingTimeInterval(931))
    try check(machine.sessions[0].state == .finished, "Expected turn completion to finish before keepHolding is considered")

    machine.applyTrustedEvent(.agentResumed, to: sessionID, at: baseline.addingTimeInterval(940))
    try check(machine.sessions[0].state == .finished, "Expected terminal finished session not to reactivate from later stale lifecycle activity")
}

private func runOutOfOrderHookEventsAreIgnored() throws {
    let machine = AgentSessionStateMachine(graceInterval: 900)
    let processStart = baseline.addingTimeInterval(-60)
    let sessionID = "codex-turn-1"

    machine.applyIntegrationEvent(
        hookEvent(.turnStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(20)
    )
    try check(machine.sessions.count == 1, "Expected hook start to create one integration session")
    try check(machine.sessions[0].state == .active, "Expected hook start to make the session active")

    machine.applyIntegrationEvent(
        hookEvent(.turnFinished, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(10)
    )
    try check(machine.sessions[0].state == .active, "Expected stale turnFinished hook not to move active session backward")

    machine.applyIntegrationEvent(
        hookEvent(.turnFinished, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(30)
    )
    try check(machine.sessions[0].state == .finished, "Expected current Codex Stop hook to finish the turn")
    try check(machine.sessions[0].standingByExpiresAt == nil, "Expected Codex Stop not to keep a grace hold")

    machine.applyIntegrationEvent(
        hookEvent(.toolStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(25)
    )
    try check(machine.sessions[0].state == .finished, "Expected stale toolStarted hook not to reactivate the finished Codex turn")

    machine.applyIntegrationEvent(
        hookEvent(.toolStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(40)
    )
    try check(machine.sessions[0].state == .finished, "Expected late toolStarted hook after Codex Stop not to reactivate the session")

    machine.applyIntegrationEvent(
        hookEvent(.turnStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(45)
    )
    try check(machine.sessions[0].state == .finished, "Expected late same-turn Codex UserPromptSubmit not to reactivate after Stop")

    machine.applyIntegrationEvent(
        hookEvent(.turnStarted, integrationSessionId: "codex-turn-2", pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(46)
    )
    try check(machine.sessions.count == 2, "Expected a new Codex turn id on the same process to create a new active turn")
    try check(machine.sessions[1].state == .active, "Expected the new Codex turn to become active")
    try check(machine.sessions[1].key.integrationSessionId == "codex-turn-2", "Expected latest Codex turn id to be retained")

    let processBackedMachine = AgentSessionStateMachine(graceInterval: 900)
    processBackedMachine.applyProcessObservations([observation(pid: 102, start: processStart)], at: baseline)
    processBackedMachine.applyIntegrationEvent(
        hookEvent(.turnFinished, integrationSessionId: "codex-turn-1", pid: 102, processStartTime: processStart),
        at: baseline.addingTimeInterval(1)
    )
    try check(processBackedMachine.sessions[0].state == .finished, "Expected Stop to finish the process-backed Codex turn")
    try check(
        processBackedMachine.sessions[0].key.integrationSessionId == "codex-turn-1",
        "Expected matched process-backed session to adopt the first Codex turn id"
    )
    processBackedMachine.applyIntegrationEvent(
        hookEvent(.turnStarted, integrationSessionId: "codex-turn-2", pid: 102, processStartTime: processStart),
        at: baseline.addingTimeInterval(2)
    )
    try check(processBackedMachine.sessions.count == 2, "Expected a different Codex turn id to create a new process-backed turn")
    try check(processBackedMachine.sessions[1].state == .active, "Expected the new process-backed Codex turn to become active")
    try check(
        processBackedMachine.sessions[1].key.integrationSessionId == "codex-turn-2",
        "Expected process-backed Codex session to adopt the latest turn id"
    )

    let missingStopMachine = AgentSessionStateMachine(
        graceInterval: 900,
        codexPostToolIdleTimeout: 30
    )
    missingStopMachine.applyIntegrationEvent(
        hookEvent(.turnStarted, integrationSessionId: "codex-turn-missing-stop", pid: 103, processStartTime: processStart),
        at: baseline
    )
    missingStopMachine.applyIntegrationEvent(
        hookEvent(.toolFinishedContinuing, integrationSessionId: "codex-turn-missing-stop", pid: 103, processStartTime: processStart),
        at: baseline.addingTimeInterval(1)
    )
    try check(
        missingStopMachine.aggregateHoldState(at: baseline.addingTimeInterval(2)).shouldHold,
        "Expected Codex post-tool activity to protect while waiting for completion"
    )
    missingStopMachine.applyProcessObservations(
        [observation(pid: 103, start: processStart, path: "/opt/homebrew/bin/codex")],
        at: baseline.addingTimeInterval(31)
    )
    try check(
        !missingStopMachine.aggregateHoldState(at: baseline.addingTimeInterval(31)).shouldHold,
        "Expected stale Codex post-tool activity to release even when the desktop process remains open"
    )
    try check(
        missingStopMachine.sessions.contains { $0.lastEvent?.kind == .staleActivityExpired },
        "Expected stale Codex post-tool activity to record an expiry event"
    )
    try check(
        missingStopMachine.sessions.contains {
            $0.source == .processScan && $0.state != .finished && !$0.hasIntegratedEvidence
        },
        "Expected the still-open Codex process to remain visible only as a detected process"
    )

    let staleClaudeMachine = AgentSessionStateMachine(
        graceInterval: 900,
        claudeActivityIdleTimeout: 30
    )
    staleClaudeMachine.applyIntegrationEvent(
        hookEvent(
            .toolStarted,
            integrationSessionId: "claude-stale-tool",
            pid: 105,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline
    )
    try check(
        staleClaudeMachine.aggregateHoldState(at: baseline.addingTimeInterval(29)).shouldHold,
        "Expected recent Claude PreToolUse activity to protect while waiting for a terminal hook"
    )
    staleClaudeMachine.applyProcessObservations(
        [observation(pid: 105, start: processStart, path: "/opt/homebrew/bin/claude", agent: .claudeCode)],
        at: baseline.addingTimeInterval(30)
    )
    try check(
        !staleClaudeMachine.aggregateHoldState(at: baseline.addingTimeInterval(30)).shouldHold,
        "Expected stale Claude tool activity to release even when the VS Code process remains open"
    )
    try check(
        staleClaudeMachine.sessions.contains { $0.lastEvent?.kind == .staleActivityExpired },
        "Expected stale Claude tool activity to record an expiry event"
    )
    try check(
        staleClaudeMachine.sessions.contains {
            $0.source == .processScan && $0.state != .finished && !$0.hasIntegratedEvidence
        },
        "Expected the still-open Claude process to remain visible only as a detected process"
    )

    let terminalMachine = AgentSessionStateMachine(graceInterval: 900)
    terminalMachine.applyIntegrationEvent(
        hookEvent(.turnStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(20)
    )
    terminalMachine.applyIntegrationEvent(
        hookEvent(.sessionFinished, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(50)
    )
    try check(terminalMachine.sessions[0].state == .finished, "Expected terminal hook to finish the session")

    terminalMachine.applyIntegrationEvent(
        hookEvent(.toolStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(60)
    )
    try check(terminalMachine.sessions.count == 1, "Expected post-terminal hook not to create a replacement session with the same integration id")
    try check(terminalMachine.sessions[0].state == .finished, "Expected post-terminal hook not to reactivate a finished integration session")

    let claudeEndedMachine = AgentSessionStateMachine(graceInterval: 900)
    let endedClaudeSessionID = "claude-ended-session"
    claudeEndedMachine.applyIntegrationEvent(
        hookEvent(
            .turnStarted,
            integrationSessionId: endedClaudeSessionID,
            pid: 104,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline.addingTimeInterval(20)
    )
    claudeEndedMachine.applyIntegrationEvent(
        hookEvent(
            .sessionFinished,
            integrationSessionId: endedClaudeSessionID,
            pid: 104,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline.addingTimeInterval(30)
    )
    claudeEndedMachine.applyIntegrationEvent(
        hookEvent(
            .turnStarted,
            integrationSessionId: endedClaudeSessionID,
            pid: 104,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline.addingTimeInterval(40)
    )
    try check(claudeEndedMachine.sessions.count == 1, "Expected Claude UserPromptSubmit after SessionEnd not to create a new turn")
    try check(claudeEndedMachine.sessions[0].state == .finished, "Expected ended Claude session to remain finished")

    let claudeFailureMachine = AgentSessionStateMachine(graceInterval: 900)
    claudeFailureMachine.applyIntegrationEvent(
        hookEvent(
            .toolStarted,
            integrationSessionId: "claude-failed-tool",
            pid: 106,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline
    )
    claudeFailureMachine.applyIntegrationEvent(
        hookEvent(
            .toolFailedContinuing,
            integrationSessionId: "claude-failed-tool",
            pid: 106,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline.addingTimeInterval(1)
    )
    try check(claudeFailureMachine.sessions[0].state == .active, "Expected Claude PostToolUseFailure to keep the turn protected")
    claudeFailureMachine.applyIntegrationEvent(
        hookEvent(
            .turnFinished,
            integrationSessionId: "claude-failed-tool",
            pid: 106,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline.addingTimeInterval(2)
    )
    try check(claudeFailureMachine.sessions[0].state == .finished, "Expected Claude StopFailure to release the protected turn")

    let multiTurnMachine = AgentSessionStateMachine(graceInterval: 5)
    let claudeSessionID = "claude-session-1"
    multiTurnMachine.applyIntegrationEvent(
        hookEvent(
            .turnStarted,
            integrationSessionId: claudeSessionID,
            pid: 101,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline
    )
    multiTurnMachine.applyIntegrationEvent(
        hookEvent(
            .turnFinished,
            integrationSessionId: claudeSessionID,
            pid: 101,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline.addingTimeInterval(1)
    )
    try check(multiTurnMachine.sessions[0].state == .finished, "Expected Claude Stop to finish the first turn immediately")
    try check(multiTurnMachine.sessions[0].standingByExpiresAt == nil, "Expected Claude Stop not to keep a grace hold")

    multiTurnMachine.applyIntegrationEvent(
        hookEvent(
            .turnStarted,
            integrationSessionId: claudeSessionID,
            pid: 101,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline.addingTimeInterval(2)
    )
    try check(multiTurnMachine.sessions.count == 2, "Expected a later Claude prompt with the same session id to create a new turn")
    try check(multiTurnMachine.sessions[1].state == .active, "Expected the later same-session Claude prompt to become active")
}

private func runManualOverridePrecedenceAndPersistence() throws {
    var current = baseline
    let monitoredProcessStart = current
    var settings = AgentWakeSettings(
        manualOverrides: [
            ManualOverride(id: "pause", kind: ManualOverrideKind.pauseAll.rawValue, expiresAt: current.addingTimeInterval(60))
        ]
    )
    let monitor = AgentMonitor(
        snapshotProvider: StaticSnapshotProvider(
            snapshotsToReturn: [
                ProcessSnapshot(
                    pid: 110,
                    processName: "codex",
                    executablePath: "/opt/homebrew/bin/codex",
                    processStartTime: monitoredProcessStart
                )
            ]
        ),
        settingsProvider: { settings },
        now: { current }
    )

    monitor.poll()
    monitor.applyIntegrationEvent(
        HookAdapterEvent(
            agent: .codexCLI,
            host: "codex-cli",
            event: .toolStarted,
            pid: 110,
            processStartTime: monitoredProcessStart,
            integrationSessionId: "manual-override-codex"
        ),
        at: current.addingTimeInterval(1)
    )
    try check(monitor.sessions.count == 1, "Expected process polling to create a held session")
    try check(!monitor.aggregateHoldState.shouldHold, "Expected persisted pause override to suppress held sessions")
    try check(monitor.aggregateHoldState.isPaused, "Expected persisted pause override to be visible in aggregate state")

    let machine = AgentSessionStateMachine()
    machine.applyProcessObservations([observation(pid: 111, start: current)], at: current)
    machine.applyManualOverrides(settings.manualOverrides, at: current)
    try check(machine.aggregateHoldState(at: current).isPaused, "Expected manual pause override to suppress direct state-machine holds")

    let keepAwakeExpiresAt = current.addingTimeInterval(120)
    machine.applyManualOverrides(
        [
            ManualOverride(id: "keep-awake", kind: ManualOverrideKind.keepAwake.rawValue, expiresAt: keepAwakeExpiresAt)
        ],
        at: current
    )
    let manualKeepAwake = machine.aggregateHoldState(at: current)
    try check(manualKeepAwake.shouldHold, "Expected manual Mac-active override to hold without a session")
    try check(manualKeepAwake.heldSessionIDs.isEmpty, "Expected manual Mac-active override not to invent a held session")
    try check(manualKeepAwake.isManuallyKeepingAwake, "Expected manual Mac-active override to be visible in aggregate state")
    try check(manualKeepAwake.manualKeepAwakeExpiresAt == keepAwakeExpiresAt, "Expected manual Mac-active expiry to be preserved")

    machine.applyManualOverrides(
        [
            ManualOverride(id: "pause", kind: ManualOverrideKind.pauseAll.rawValue, expiresAt: current.addingTimeInterval(60)),
            ManualOverride(id: "keep-awake", kind: ManualOverrideKind.keepAwake.rawValue, expiresAt: keepAwakeExpiresAt)
        ],
        at: current
    )
    let pauseDuringManualKeepAwake = machine.aggregateHoldState(at: current)
    try check(pauseDuringManualKeepAwake.isPaused, "Expected pause override to suppress manual Mac-active hold")
    try check(!pauseDuringManualKeepAwake.shouldHold, "Expected pause override to release manual Mac-active assertions")

    machine.setSafetyCutoffActive(true)
    let safetyDuringPause = machine.aggregateHoldState(at: current)
    try check(safetyDuringPause.isSafetyCutoffActive, "Expected safety cutoff to take precedence over manual pause")
    try check(!safetyDuringPause.isPaused, "Expected aggregate state to report the higher-priority safety cutoff")
    machine.setSafetyCutoffActive(false)

    settings.manualOverrides = [
        ManualOverride(id: "safety", kind: ManualOverrideKind.safetyCutoff.rawValue, expiresAt: current.addingTimeInterval(5))
    ]
    current = current.addingTimeInterval(1)
    monitor.poll()
    try check(monitor.aggregateHoldState.isSafetyCutoffActive, "Expected persisted safety override to suppress holds")
    try check(!monitor.aggregateHoldState.isPaused, "Expected safety override to take precedence over an expired previous pause")

    current = current.addingTimeInterval(6)
    try check(monitor.aggregateHoldState.shouldHold, "Expected expired safety override not to linger between polls")
    try check(!monitor.aggregateHoldState.isSafetyCutoffActive, "Expected expired safety override to stop suppressing holds")

    settings.manualOverrides = []
    current = current.addingTimeInterval(1)
    monitor.poll()
    try check(monitor.aggregateHoldState.shouldHold, "Expected removing persisted overrides to restore held sessions")
    try check(!monitor.aggregateHoldState.isPaused, "Expected removed persisted pause override not to linger")
    try check(!monitor.aggregateHoldState.isSafetyCutoffActive, "Expected removed persisted safety override not to linger")

    settings.manualOverrides = [
        ManualOverride(id: "expired", kind: ManualOverrideKind.pauseAll.rawValue, expiresAt: current.addingTimeInterval(-1))
    ]
    monitor.poll()
    try check(monitor.aggregateHoldState.shouldHold, "Expected expired persisted pause override not to suppress holds")

    settings.manualOverrides = [
        ManualOverride(id: "indefinite-keep", kind: ManualOverrideKind.keepAwake.rawValue)
    ]
    let emptyManualKeepAwakeMonitor = AgentMonitor(
        snapshotProvider: StaticSnapshotProvider(snapshotsToReturn: []),
        settingsProvider: { settings },
        now: { current }
    )
    emptyManualKeepAwakeMonitor.poll()
    try check(emptyManualKeepAwakeMonitor.aggregateHoldState.shouldHold, "Expected indefinite Mac-active override to hold without sessions")
    try check(emptyManualKeepAwakeMonitor.aggregateHoldState.isManuallyKeepingAwake, "Expected indefinite Mac-active override to be visible")
    try check(emptyManualKeepAwakeMonitor.aggregateHoldState.manualKeepAwakeExpiresAt == nil, "Expected indefinite Mac-active override to have no expiry")

    settings.manualOverrides = [
        ManualOverride(id: "fallback-pause", kind: ManualOverrideKind.pauseAll.rawValue, expiresAt: current.addingTimeInterval(60))
    ]
    let fallbackMonitor = AgentMonitor(
        snapshotProvider: ThrowingSnapshotProvider(),
        settingsProvider: { settings },
        now: { current }
    )
    fallbackMonitor.poll()
    try check(fallbackMonitor.aggregateHoldState.isPaused, "Expected persisted pause override to apply even when process snapshots fail")
}

private func observation(
    pid: Int32,
    start: Date,
    path: String = "/opt/homebrew/bin/codex",
    agent: AgentKind = .codexCLI,
    cpuPercent: Double? = nil
) -> AgentProcessObservation {
    let snapshot = ProcessSnapshot(
        pid: pid,
        processName: URL(fileURLWithPath: path).lastPathComponent,
        executablePath: path,
        processStartTime: start,
        cpuPercent: cpuPercent
    )
    return AgentProcessObservation(
        agent: agent,
        snapshot: snapshot,
        key: SessionKey(
            pid: pid,
            processStartTime: start,
            executablePathHash: StablePathHash.sha256(path),
            executablePathHashIsVerified: true
        )
    )
}

private func observationWithMissingPath(
    pid: Int32,
    start: Date,
    processName: String = "codex",
    agent: AgentKind = .codexCLI
) -> AgentProcessObservation {
    let snapshot = ProcessSnapshot(
        pid: pid,
        processName: processName,
        executablePath: nil,
        processStartTime: start
    )
    return AgentProcessObservation(
        agent: agent,
        snapshot: snapshot,
        key: SessionKey(
            pid: pid,
            processStartTime: start,
            executablePathHash: StablePathHash.sha256("process:\(processName)"),
            executablePathHashIsVerified: false
        )
    )
}

private func hookEvent(
    _ event: HookAdapterEventKind,
    integrationSessionId: String,
    pid: Int32,
    processStartTime: Date,
    agent: AgentKind = .codexCLI
) -> HookAdapterEvent {
    HookAdapterEvent(
        agent: agent,
        host: agent.rawValue,
        event: event,
        pid: pid,
        processStartTime: processStartTime,
        integrationSessionId: integrationSessionId
    )
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure(message)
    }
}

private func checkNotNil<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw TestFailure(message)
    }

    return value
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct StaticSnapshotProvider: ProcessSnapshotProviding {
    var snapshotsToReturn: [ProcessSnapshot]

    func snapshots() throws -> [ProcessSnapshot] {
        snapshotsToReturn
    }
}

private struct ThrowingSnapshotProvider: ProcessSnapshotProviding {
    func snapshots() throws -> [ProcessSnapshot] {
        throw TestFailure("snapshot failure")
    }
}

private final class CountingSnapshotProvider: ProcessSnapshotProviding {
    var snapshotsToReturn: [ProcessSnapshot]
    private let lock = NSLock()
    private var count = 0

    init(snapshotsToReturn: [ProcessSnapshot]) {
        self.snapshotsToReturn = snapshotsToReturn
    }

    var callCount: Int {
        lock.withLock {
            count
        }
    }

    func snapshots() throws -> [ProcessSnapshot] {
        lock.withLock {
            count += 1
        }
        return snapshotsToReturn
    }
}
#endif
