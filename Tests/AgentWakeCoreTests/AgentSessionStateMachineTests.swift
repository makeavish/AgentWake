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

    @Test func processOnlyDetectionDoesNotProtectWithoutIntegration() throws {
        try runProcessOnlyDetectionDoesNotProtectWithoutIntegration()
    }

    @Test func agentMonitorStartUsesTimerCadence() throws {
        try runAgentMonitorStartUsesTimerCadence()
    }

    @Test func transitionMatrixCoversActivityStandbyGraceAndFinish() throws {
        try runTransitionMatrixCoversActivityStandbyGraceAndFinish()
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

    func testReleaseNowSuppressesProcessOnlyProvisionalRehold() throws {
        try runProcessOnlyDetectionDoesNotProtectWithoutIntegration()
    }

    func testAgentMonitorStartUsesTimerCadence() throws {
        try runAgentMonitorStartUsesTimerCadence()
    }

    func testTransitionMatrixCoversActivityStandbyGraceAndFinish() throws {
        try runTransitionMatrixCoversActivityStandbyGraceAndFinish()
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

    machine.applyProcessObservations([observationWithMissingPath(pid: 43, start: baseline)], at: baseline)
    let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected fallback process session")
    machine.applyTrustedEvent(.turnFinished, to: sessionID, at: baseline.addingTimeInterval(10))
    let expiry = try checkNotNil(machine.sessions.first?.standingByExpiresAt, "Expected standing-by expiry")

    machine.applyProcessObservations(
        [observation(pid: 43, start: baseline, path: "/opt/homebrew/bin/codex")],
        at: baseline.addingTimeInterval(20)
    )

    try check(machine.sessions.count == 1, "Expected path hash upgrade not to split the same pid/start process")
    try check(machine.sessions[0].id == sessionID, "Expected path hash upgrade to preserve session identity")
    try check(machine.sessions[0].state == .standingBy, "Expected path hash upgrade not to reactivate the session")
    try check(machine.sessions[0].standingByExpiresAt == expiry, "Expected path hash upgrade not to reset grace")
    try check(machine.sessions[0].key.executablePathHash == StablePathHash.sha256("/opt/homebrew/bin/codex"), "Expected path hash to upgrade when a verified path appears")
    try check(machine.sessions[0].key.executablePathHashIsVerified, "Expected upgraded path hash to be marked verified")
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
        monitor.sessionSummaryMessage() == "Sessions: 3 seen, none protecting",
        "Expected process-only detections to remain diagnostic until hook evidence arrives: \(monitor.sessionSummaryMessage())"
    )
    try check(
        monitor.sessionListMessage().contains("Codex CLI: seen source=processScan pid=32"),
        "Expected process-only detection to be labeled seen: \(monitor.sessionListMessage())"
    )

    currentDate = currentDate.addingTimeInterval(901)
    try check(
        monitor.sessionSummaryMessage() == "Sessions: 3 seen, none protecting",
        "Expected process-only detections to stay diagnostic without hook evidence: \(monitor.sessionSummaryMessage())"
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

    machine.applyIntegrationEvent(
        HookAdapterEvent(
            agent: .claudeCode,
            host: "claude-code",
            event: .toolStarted,
            pid: 34,
            processStartTime: baseline.addingTimeInterval(-30),
            integrationSessionId: "claude-after-release"
        ),
        at: baseline.addingTimeInterval(3)
    )
    try check(
        machine.aggregateHoldState(at: baseline.addingTimeInterval(3)).shouldHold,
        "Expected a real integration event to start protection"
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

private func runTransitionMatrixCoversActivityStandbyGraceAndFinish() throws {
    let machine = AgentSessionStateMachine(graceInterval: 900)
    machine.applyProcessObservations([observation(pid: 50, start: baseline)], at: baseline)
    let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected active process-backed session")

    try check(machine.sessions[0].state == .active, "Expected matching process start to create an active session")
    try check(!machine.aggregateHoldState(at: baseline).shouldHold, "Expected process-only session not to protect")
    try check(
        !machine.aggregateHoldState(at: baseline.addingTimeInterval(901)).shouldHold,
        "Expected process-only session to remain diagnostic without integration evidence"
    )
    machine.applyIntegrationEvent(
        HookAdapterEvent(
            agent: .codexCLI,
            host: "codex-cli",
            event: .toolStarted,
            pid: 50,
            processStartTime: baseline,
            integrationSessionId: "codex-turn-50"
        ),
        at: baseline.addingTimeInterval(1)
    )
    try check(machine.aggregateHoldState(at: baseline.addingTimeInterval(1)).shouldHold, "Expected integration-backed session to hold")

    let turnFinishedAt = baseline.addingTimeInterval(10)
    machine.applyTrustedEvent(.turnFinished, to: sessionID, at: turnFinishedAt)
    try check(machine.sessions[0].state == .standingBy, "Expected turn finish to enter standing by")
    try check(machine.sessions[0].standingByExpiresAt == turnFinishedAt.addingTimeInterval(900), "Expected default 15 minute grace")

    let resumedAt = baseline.addingTimeInterval(20)
    machine.applyTrustedEvent(.agentResumed, to: sessionID, at: resumedAt)
    try check(machine.sessions[0].state == .active, "Expected trusted resumed event to reactivate")
    try check(machine.sessions[0].lastActivityAt == resumedAt, "Expected trusted activity to reset last activity")
    try check(machine.sessions[0].standingByExpiresAt == nil, "Expected trusted activity to clear standing-by expiry")

    let secondTurnFinishedAt = baseline.addingTimeInterval(30)
    machine.applyTrustedEvent(.turnFinished, to: sessionID, at: secondTurnFinishedAt)
    machine.applyTrustedEvent(.keepHolding, to: sessionID, at: baseline.addingTimeInterval(40))
    try check(
        machine.sessions[0].standingByExpiresAt == secondTurnFinishedAt.addingTimeInterval(1_800),
        "Expected keep holding to extend by one additional grace window"
    )

    machine.refreshExpirations(at: secondTurnFinishedAt.addingTimeInterval(1_801))
    try check(machine.sessions[0].state == .finished, "Expected grace expiry to finish hold decisions")
    try check(!machine.aggregateHoldState(at: secondTurnFinishedAt.addingTimeInterval(1_801)).shouldHold, "Expected expired session not to hold")
}

private func runCPUDiagnosticsDoNotResetActivityOrGrace() throws {
    let machine = AgentSessionStateMachine(graceInterval: 900)
    machine.applyProcessObservations([observation(pid: 60, start: baseline, cpuPercent: 1)], at: baseline)
    let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected active session")

    machine.applyProcessObservations(
        [observation(pid: 60, start: baseline, cpuPercent: 88)],
        at: baseline.addingTimeInterval(120)
    )
    try check(machine.sessions[0].lastActivityAt == baseline, "Expected CPU changes not to reset active timestamp")

    let turnFinishedAt = baseline.addingTimeInterval(180)
    machine.applyTrustedEvent(.turnFinished, to: sessionID, at: turnFinishedAt)
    let originalExpiry = try checkNotNil(machine.sessions[0].standingByExpiresAt, "Expected standing-by expiry")

    machine.applyProcessObservations(
        [observation(pid: 60, start: baseline, cpuPercent: 0)],
        at: baseline.addingTimeInterval(240)
    )
    try check(machine.sessions[0].state == .standingBy, "Expected process presence not to reactivate standing-by session")
    try check(machine.sessions[0].standingByExpiresAt == originalExpiry, "Expected CPU/process polling not to extend grace")
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
    try check(machine.aggregateHoldState(at: baseline.addingTimeInterval(30)).shouldHold, "Expected standing-by Claude session to keep aggregate hold active")

    machine.refreshExpirations(at: baseline.addingTimeInterval(911))
    try check(!machine.aggregateHoldState(at: baseline.addingTimeInterval(911)).shouldHold, "Expected aggregate hold to release only after all sessions finish or expire")
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
    try check(machine.sessions[0].state == .finished, "Expected expired grace to finish before keepHolding is considered")

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
    try check(machine.sessions[0].state == .standingBy, "Expected current turnFinished hook to enter standing by")
    try check(
        machine.sessions[0].standingByExpiresAt == baseline.addingTimeInterval(930),
        "Expected standing-by expiry from the accepted turnFinished hook"
    )

    machine.applyIntegrationEvent(
        hookEvent(.toolStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(25)
    )
    try check(machine.sessions[0].state == .standingBy, "Expected stale toolStarted hook not to reactivate standing-by session")
    try check(
        machine.sessions[0].standingByExpiresAt == baseline.addingTimeInterval(930),
        "Expected stale toolStarted hook not to alter standing-by expiry"
    )

    machine.applyIntegrationEvent(
        hookEvent(.toolStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(40)
    )
    try check(machine.sessions[0].state == .standingBy, "Expected late toolStarted hook after turnFinished not to reactivate the session")

    machine.applyIntegrationEvent(
        hookEvent(.turnStarted, integrationSessionId: sessionID, pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(45)
    )
    try check(machine.sessions[0].state == .standingBy, "Expected late same-turn Codex UserPromptSubmit not to reactivate after Stop")

    machine.applyIntegrationEvent(
        hookEvent(.turnStarted, integrationSessionId: "codex-turn-2", pid: 100, processStartTime: processStart),
        at: baseline.addingTimeInterval(46)
    )
    try check(machine.sessions.count == 2, "Expected a new Codex turn id to create a separate active session")
    try check(machine.sessions[1].state == .active, "Expected the new Codex turn to become active")

    let processBackedMachine = AgentSessionStateMachine(graceInterval: 900)
    processBackedMachine.applyProcessObservations([observation(pid: 102, start: processStart)], at: baseline)
    processBackedMachine.applyIntegrationEvent(
        hookEvent(.turnFinished, integrationSessionId: "codex-turn-1", pid: 102, processStartTime: processStart),
        at: baseline.addingTimeInterval(1)
    )
    try check(processBackedMachine.sessions[0].state == .standingBy, "Expected Stop to move the process-backed Codex turn to standing by")
    try check(
        processBackedMachine.sessions[0].key.integrationSessionId == "codex-turn-1",
        "Expected matched process-backed session to adopt the first Codex turn id"
    )
    processBackedMachine.applyIntegrationEvent(
        hookEvent(.turnStarted, integrationSessionId: "codex-turn-2", pid: 102, processStartTime: processStart),
        at: baseline.addingTimeInterval(2)
    )
    try check(processBackedMachine.sessions.count == 2, "Expected a different Codex turn id not to be swallowed by PID fallback")
    try check(processBackedMachine.sessions[1].state == .active, "Expected the new process-backed Codex turn to become active")

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
    multiTurnMachine.refreshExpirations(at: baseline.addingTimeInterval(7))
    try check(multiTurnMachine.sessions[0].state == .finished, "Expected grace expiry to finish the first Claude turn")

    multiTurnMachine.applyIntegrationEvent(
        hookEvent(
            .turnStarted,
            integrationSessionId: claudeSessionID,
            pid: 101,
            processStartTime: processStart,
            agent: .claudeCode
        ),
        at: baseline.addingTimeInterval(8)
    )
    try check(multiTurnMachine.sessions.count == 2, "Expected a later Claude prompt with the same session id to create a new turn after grace expiry")
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

private func observationWithMissingPath(pid: Int32, start: Date) -> AgentProcessObservation {
    let snapshot = ProcessSnapshot(
        pid: pid,
        processName: "codex",
        executablePath: nil,
        processStartTime: start
    )
    return AgentProcessObservation(
        agent: .codexCLI,
        snapshot: snapshot,
        key: SessionKey(
            pid: pid,
            processStartTime: start,
            executablePathHash: StablePathHash.sha256("process:codex"),
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
