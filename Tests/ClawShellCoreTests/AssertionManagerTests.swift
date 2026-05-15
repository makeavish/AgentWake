import Foundation

#if canImport(Testing)
import Testing
@testable import ClawShellCore

struct AssertionManagerTests {
    @Test func managerAcquiresValidatedNormalAssertionsAndReleases() throws {
        try runManagerAcquiresValidatedNormalAssertionsAndReleases()
    }

    @Test func pauseAndReleaseOverridesStopAssertions() throws {
        try runPauseAndReleaseOverridesStopAssertions()
    }

    @Test func partialCreateFailureKeepsAcquiredAssertionsAndRetriesMissingOnes() throws {
        try runPartialCreateFailureKeepsAcquiredAssertionsAndRetriesMissingOnes()
    }

    @Test func failedReleaseRemainsTrackedAndRetriesWithoutHidingError() throws {
        try runFailedReleaseRemainsTrackedAndRetriesWithoutHidingError()
    }

    @Test func controlRouterPauseAndReleaseReconcileAssertions() throws {
        try runControlRouterPauseAndReleaseReconcileAssertions()
    }

    @Test func stopReleasesHeldAssertions() throws {
        try runStopReleasesHeldAssertions()
    }

    @Test func stopWithFailedReleaseDoesNotReportStoppedUntilRetryCompletes() throws {
        try runStopWithFailedReleaseDoesNotReportStoppedUntilRetryCompletes()
    }

    @Test func stoppedManagerDoesNotReacquireAssertions() throws {
        try runStoppedManagerDoesNotReacquireAssertions()
    }

    @Test func defaultPolicyAvoidsDisplayAndDiskAssertions() throws {
        try runDefaultPolicyAvoidsDisplayAndDiskAssertions()
    }

    @Test func defaultReconcileIntervalMeetsReleaseSLA() throws {
        try runDefaultReconcileIntervalMeetsReleaseSLA()
    }
}

#elseif canImport(XCTest)
import XCTest
@testable import ClawShellCore

final class AssertionManagerTests: XCTestCase {
    func testManagerAcquiresValidatedNormalAssertionsAndReleases() throws {
        try runManagerAcquiresValidatedNormalAssertionsAndReleases()
    }

    func testPauseAndReleaseOverridesStopAssertions() throws {
        try runPauseAndReleaseOverridesStopAssertions()
    }

    func testPartialCreateFailureKeepsAcquiredAssertionsAndRetriesMissingOnes() throws {
        try runPartialCreateFailureKeepsAcquiredAssertionsAndRetriesMissingOnes()
    }

    func testFailedReleaseRemainsTrackedAndRetriesWithoutHidingError() throws {
        try runFailedReleaseRemainsTrackedAndRetriesWithoutHidingError()
    }

    func testControlRouterPauseAndReleaseReconcileAssertions() throws {
        try runControlRouterPauseAndReleaseReconcileAssertions()
    }

    func testStopReleasesHeldAssertions() throws {
        try runStopReleasesHeldAssertions()
    }

    func testStopWithFailedReleaseDoesNotReportStoppedUntilRetryCompletes() throws {
        try runStopWithFailedReleaseDoesNotReportStoppedUntilRetryCompletes()
    }

    func testStoppedManagerDoesNotReacquireAssertions() throws {
        try runStoppedManagerDoesNotReacquireAssertions()
    }

    func testDefaultPolicyAvoidsDisplayAndDiskAssertions() throws {
        try runDefaultPolicyAvoidsDisplayAndDiskAssertions()
    }

    func testDefaultReconcileIntervalMeetsReleaseSLA() throws {
        try runDefaultReconcileIntervalMeetsReleaseSLA()
    }
}

#else
#error("This toolchain does not provide Testing or XCTest. Run `swift run ClawShellCoreChecks` for portable checks.")
#endif

#if canImport(Testing) || canImport(XCTest)
private func runManagerAcquiresValidatedNormalAssertionsAndReleases() throws {
    let controller = RecordingPowerAssertionController()
    let heldSessionID = UUID()
    var holdState = AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])
    let manager = AssertionManager(
        controller: controller,
        holdStateProvider: { holdState },
        reconcileInterval: 60
    )

    manager.start()
    try check(controller.createdTypes.isEmpty, "Expected no assertion while aggregate hold is false")

    holdState = AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [heldSessionID])
    manager.reconcile()

    try check(
        controller.createdTypes == [.preventUserIdleSystemSleep],
        "Expected validated normal assertion set"
    )
    try check(manager.snapshot.isHolding, "Expected manager snapshot to report active hold")

    holdState = AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])
    manager.reconcile()

    try check(controller.releasedIDs.count == 1, "Expected normal assertion to release")
    try check(!manager.snapshot.isHolding, "Expected manager snapshot to report released state")
    manager.stop()
}

private func runPauseAndReleaseOverridesStopAssertions() throws {
    let controller = RecordingPowerAssertionController()
    var holdState = AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()])
    let manager = AssertionManager(
        controller: controller,
        holdStateProvider: { holdState },
        reconcileInterval: 60
    )

    manager.start()
    try check(manager.snapshot.isHolding, "Expected initial aggregate hold to create assertions")

    holdState = AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [], isPaused: true)
    manager.reconcile()
    try check(!manager.snapshot.isHolding, "Expected pause override to release assertions")

    holdState = AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])
    manager.reconcile()
    try check(controller.createdTypes.count == 1, "Expected release-now false hold state not to reacquire assertions")
    manager.stop()
}

private func runPartialCreateFailureKeepsAcquiredAssertionsAndRetriesMissingOnes() throws {
    let controller = RecordingPowerAssertionController()
    controller.createFailures[.preventDiskIdle] = PowerAssertionError.createFailed(type: .preventDiskIdle, code: -1)
    let policy = NormalPowerAssertionPolicy(assertionTypes: [.preventUserIdleSystemSleep, .preventDiskIdle])
    let manager = AssertionManager(
        controller: controller,
        policy: policy,
        holdStateProvider: { AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()]) },
        reconcileInterval: 60
    )

    manager.start()
    try check(manager.snapshot.heldAssertions.map(\.type) == [.preventUserIdleSystemSleep], "Expected successful assertion to stay tracked")
    try check(manager.snapshot.lastErrorDescription != nil, "Expected create failure to stay visible")

    controller.createFailures.removeAll()
    manager.reconcile()
    try check(
        manager.snapshot.heldAssertions.map(\.type) == [.preventDiskIdle, .preventUserIdleSystemSleep],
        "Expected missing assertion type to be created on retry"
    )
    try check(manager.snapshot.lastErrorDescription == nil, "Expected retry success to clear create error")
    manager.stop()
}

private func runFailedReleaseRemainsTrackedAndRetriesWithoutHidingError() throws {
    let controller = RecordingPowerAssertionController()
    let policy = NormalPowerAssertionPolicy(assertionTypes: [.preventUserIdleSystemSleep, .preventDiskIdle])
    var holdState = AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()])
    let manager = AssertionManager(
        controller: controller,
        policy: policy,
        holdStateProvider: { holdState },
        reconcileInterval: 60
    )

    manager.start()
    controller.releaseFailures = [PowerAssertionID(rawValue: 1)]
    holdState = AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])
    manager.reconcile()

    try check(manager.snapshot.heldAssertions.map(\.type) == [.preventUserIdleSystemSleep], "Expected failed release to remain tracked")
    try check(manager.snapshot.lastErrorDescription != nil, "Expected failed release error to remain visible")

    holdState = AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()])
    controller.releaseFailures.removeAll()
    manager.reconcile()
    try check(
        manager.snapshot.heldAssertions.map(\.type) == [.preventDiskIdle, .preventUserIdleSystemSleep],
        "Expected re-hold to recreate missing desired assertion"
    )
    try check(manager.snapshot.lastErrorDescription == nil, "Expected successful reconcile to clear release error")
    manager.stop()
}

private func runControlRouterPauseAndReleaseReconcileAssertions() throws {
    var current = Date(timeIntervalSince1970: 9_000)
    let monitoredProcessStart = current
    let monitor = AgentMonitor(
        snapshotProvider: StaticSnapshotProvider(
            snapshotsToReturn: [
                ProcessSnapshot(
                    pid: 41,
                    processName: "codex",
                    executablePath: "/opt/homebrew/bin/codex",
                    processStartTime: monitoredProcessStart
                )
            ]
        ),
        now: { current }
    )
    let controller = RecordingPowerAssertionController()
    let manager = AssertionManager(
        controller: controller,
        holdStateProvider: { monitor.aggregateHoldState },
        reconcileInterval: 60
    )
    let router = DefaultControlCommandRouter(
        pauseHandler: { duration, receivedAt in
            monitor.pauseAll(until: receivedAt.addingTimeInterval(duration))
            manager.reconcile()
        },
        releaseNowHandler: { receivedAt in
            monitor.releaseHeldSessions(at: receivedAt)
            manager.reconcile()
        }
    )

    monitor.start()
    monitor.applyIntegrationEvent(
        HookAdapterEvent(
            agent: .codexCLI,
            host: "codex-cli",
            event: .toolStarted,
            pid: 41,
            processStartTime: monitoredProcessStart,
            integrationSessionId: "router-codex"
        ),
        at: current.addingTimeInterval(1)
    )
    manager.start()
    try check(manager.snapshot.isHolding, "Expected process-backed session to hold assertions")

    _ = try router.route(.pause(duration: 60), receivedAt: current)
    try check(!manager.snapshot.isHolding, "Expected pause command to release assertions")

    current = current.addingTimeInterval(61)
    monitor.poll()
    manager.reconcile()
    try check(manager.snapshot.isHolding, "Expected assertions to resume after pause expiry")

    _ = try router.route(.releaseNow, receivedAt: current)
    try check(!manager.snapshot.isHolding, "Expected release now command to release assertions")

    manager.stop()
    monitor.stop()
}

private func runStopReleasesHeldAssertions() throws {
    let controller = RecordingPowerAssertionController()
    let manager = AssertionManager(
        controller: controller,
        holdStateProvider: { AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()]) },
        reconcileInterval: 60
    )

    manager.start()
    try check(manager.snapshot.isHolding, "Expected manager to hold after start")

    manager.stop()

    try check(controller.releasedIDs.count == 1, "Expected stop to release held assertion")
    try check(manager.snapshot.runState == .stopped, "Expected manager to report stopped state")
    try check(!manager.snapshot.isHolding, "Expected stopped manager to report no active assertions")
}

private func runStopWithFailedReleaseDoesNotReportStoppedUntilRetryCompletes() throws {
    let controller = RecordingPowerAssertionController()
    let manager = AssertionManager(
        controller: controller,
        holdStateProvider: { AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()]) },
        reconcileInterval: 60
    )

    manager.start()
    controller.releaseFailures = [PowerAssertionID(rawValue: 1)]
    manager.stop()

    try check(manager.snapshot.runState == .started, "Expected manager not to report stopped while release retry is pending")
    try check(manager.snapshot.isHolding, "Expected failed release to remain tracked after stop")
    try check(manager.snapshot.lastErrorDescription != nil, "Expected stop release failure to stay visible")

    controller.releaseFailures.removeAll()
    manager.reconcile()

    try check(manager.snapshot.runState == .stopped, "Expected manager to report stopped after release retry succeeds")
    try check(!manager.snapshot.isHolding, "Expected retry to clear held assertion")
}

private func runStoppedManagerDoesNotReacquireAssertions() throws {
    let controller = RecordingPowerAssertionController()
    let manager = AssertionManager(
        controller: controller,
        holdStateProvider: { AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()]) },
        reconcileInterval: 60
    )

    manager.start()
    manager.stop()
    manager.reconcile()

    try check(controller.createdTypes.count == 1, "Expected stopped reconcile not to reacquire assertions")
    try check(manager.snapshot.runState == .stopped, "Expected manager to remain stopped")
    try check(!manager.snapshot.isHolding, "Expected stopped manager not to hold assertions")
}

private func runDefaultPolicyAvoidsDisplayAndDiskAssertions() throws {
    let defaults = NormalPowerAssertionPolicy.validatedDefault.assertionTypes
    try check(defaults == [.preventUserIdleSystemSleep], "Expected user-idle system sleep assertion by default")
    try check(!defaults.contains(.preventDisplaySleep), "Expected display sleep assertion to stay disabled by default")
    try check(!defaults.contains(.preventDiskIdle), "Expected disk idle assertion to stay out of default set")
    try check(!defaults.contains(.preventSystemSleep), "Expected unsupported system sleep assertion to stay out of default set")
    try check(
        NormalPowerAssertionPolicy.validationCandidateAssertionTypes.contains(.preventDiskIdle),
        "Expected disk idle to remain an explicit validation candidate"
    )
}

private func runDefaultReconcileIntervalMeetsReleaseSLA() throws {
    let manager = AssertionManager()
    try check(manager.reconcileInterval <= 30, "Expected assertion release polling interval within 30 seconds")
}

private final class RecordingPowerAssertionController: PowerAssertionControlling {
    var createdTypes: [PowerAssertionType] = []
    var releasedIDs: [PowerAssertionID] = []
    var createFailures: [PowerAssertionType: Error] = [:]
    var releaseFailures: Set<PowerAssertionID> = []
    private var nextID: UInt32 = 1

    func createAssertion(type: PowerAssertionType, reason: String) throws -> PowerAssertionID {
        createdTypes.append(type)
        if let failure = createFailures[type] {
            throw failure
        }
        defer { nextID += 1 }
        return PowerAssertionID(rawValue: nextID)
    }

    func releaseAssertion(_ id: PowerAssertionID) throws {
        releasedIDs.append(id)
        if releaseFailures.contains(id) {
            throw PowerAssertionError.releaseFailed(id: id, code: -1)
        }
    }
}

private struct StaticSnapshotProvider: ProcessSnapshotProviding {
    var snapshotsToReturn: [ProcessSnapshot]

    func snapshots() throws -> [ProcessSnapshot] {
        snapshotsToReturn
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure(message)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
