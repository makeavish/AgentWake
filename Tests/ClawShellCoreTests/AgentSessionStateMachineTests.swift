import Foundation

#if canImport(Testing)
import Testing
@testable import ClawShellCore

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
}

#elseif canImport(XCTest)
import XCTest
@testable import ClawShellCore

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
}

#else
#error("This toolchain does not provide Testing or XCTest. Run `swift run ClawShellCoreChecks` for portable checks.")
#endif

#if canImport(Testing) || canImport(XCTest)
private let baseline = Date(timeIntervalSince1970: 1_000)

private func runDetectorMatchesBuiltInAgentsWithPathHashes() throws {
    let detector = AgentProcessDetector(settings: ClawShellSettings())
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
        settingsProvider: { ClawShellSettings() },
        now: { baseline }
    )

    try check(monitor.pollInterval == 2, "Expected default process polling interval to be two seconds")
    monitor.poll()
    try check(monitor.sessions.count == 1, "Expected monitor poll to normalize snapshots into sessions")
    try check(monitor.sessions.first?.agent == .codexCLI, "Expected monitor to detect Codex CLI")
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
        settingsProvider: { ClawShellSettings() },
        pollInterval: 0.01,
        now: { baseline }
    )

    monitor.start()
    Thread.sleep(forTimeInterval: 0.05)
    monitor.stop()

    try check(provider.callCount >= 2, "Expected start() to perform an immediate poll and continue on the configured cadence")
}

private func runTransitionMatrixCoversActivityStandbyGraceAndFinish() throws {
    let machine = AgentSessionStateMachine(graceInterval: 900)
    machine.applyProcessObservations([observation(pid: 50, start: baseline)], at: baseline)
    let sessionID = try checkNotNil(machine.sessions.first?.id, "Expected active process-backed session")

    try check(machine.sessions[0].state == .active, "Expected matching process start to create an active session")
    try check(machine.aggregateHoldState(at: baseline).shouldHold, "Expected active session to hold")

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
