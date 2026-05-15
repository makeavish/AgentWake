import Foundation

#if canImport(Testing)
import Testing
@testable import AgentWakeCore

struct MenuBarModelTests {
    @Test func snapshotIncludesRuntimeDiagnostics() {
        let snapshot = MenuBarModel.snapshot(
            currentState: .idle,
            sessionSummary: "Sessions: none seen",
            integrationStatuses: [
                IntegrationStatusSnapshot(
                    agentID: "claude-code",
                    displayName: "Claude Code",
                    status: .installed
                )
            ]
        )

        #expect(snapshot.items.map(\.title).contains("Sessions: none seen"))
        #expect(snapshot.items.map(\.title).contains(ClosedLidModeAvailability.unavailableTitle))
        #expect(snapshot.items.map(\.title).contains("Claude Code: Installed"))
        #expect(snapshot.items.map(\.title).contains("Refresh Status"))
        #expect(snapshot.items.map(\.title).contains("Repair Integrations..."))
    }

    @Test func snapshotNamesTheCurrentState() {
        let snapshot = MenuBarModel.snapshot(currentState: .bagMode)

        #expect(snapshot.currentState == .bagMode)
        #expect(snapshot.statusItemTitle == "AgentWake")
        #expect(snapshot.items.first?.title == "Current: \(ClosedLidModeAvailability.unavailableTitle)")
        #expect(snapshot.items.first?.detail == ClosedLidModeAvailability.settingsDetail)
    }

    @Test func stateDerivesFromHoldState() {
        #expect(AgentWakeState.derived(from: AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])) == .idle)
        #expect(AgentWakeState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()])) == .active)
        #expect(AgentWakeState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [], isPaused: true)) == .paused)
        #expect(AgentWakeState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [], isSafetyCutoffActive: true)) == .paused)
    }

    @Test func lifecycleComponentsCanStartAndStopTogether() throws {
        let paths = try makeTemporaryPaths()
        let services = AgentWakeServices(paths: paths)

        services.startAll()
        #expect(services.lifecycleComponents.allSatisfy { $0.runState == .started })
        #expect(services.logStore.events.map(\.kind).contains(.appStarted))

        services.stopAll()
        #expect(services.lifecycleComponents.allSatisfy { $0.runState == .stopped })
        #expect(services.logStore.events.map(\.kind).contains(.appStopped))
    }
}

#elseif canImport(XCTest)
import XCTest
@testable import AgentWakeCore

final class MenuBarModelTests: XCTestCase {
    func testSnapshotIncludesRuntimeDiagnostics() {
        let snapshot = MenuBarModel.snapshot(
            currentState: .idle,
            sessionSummary: "Sessions: none seen",
            integrationStatuses: [
                IntegrationStatusSnapshot(
                    agentID: "claude-code",
                    displayName: "Claude Code",
                    status: .installed
                )
            ]
        )

        XCTAssertTrue(snapshot.items.map(\.title).contains("Sessions: none seen"))
        XCTAssertTrue(snapshot.items.map(\.title).contains(ClosedLidModeAvailability.unavailableTitle))
        XCTAssertTrue(snapshot.items.map(\.title).contains("Claude Code: Installed"))
        XCTAssertTrue(snapshot.items.map(\.title).contains("Refresh Status"))
        XCTAssertTrue(snapshot.items.map(\.title).contains("Repair Integrations..."))
    }

    func testSnapshotNamesTheCurrentState() {
        let snapshot = MenuBarModel.snapshot(currentState: .bagMode)

        XCTAssertEqual(snapshot.currentState, .bagMode)
        XCTAssertEqual(snapshot.statusItemTitle, "AgentWake")
        XCTAssertEqual(snapshot.items.first?.title, "Current: \(ClosedLidModeAvailability.unavailableTitle)")
        XCTAssertEqual(snapshot.items.first?.detail, ClosedLidModeAvailability.settingsDetail)
    }

    func testStateDerivesFromHoldState() {
        XCTAssertEqual(AgentWakeState.derived(from: AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])), .idle)
        XCTAssertEqual(AgentWakeState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()])), .active)
        XCTAssertEqual(AgentWakeState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [], isPaused: true)), .paused)
        XCTAssertEqual(AgentWakeState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [], isSafetyCutoffActive: true)), .paused)
    }

    func testLifecycleComponentsCanStartAndStopTogether() throws {
        let paths = try makeTemporaryPaths()
        let services = AgentWakeServices(paths: paths)

        services.startAll()
        XCTAssertTrue(services.lifecycleComponents.allSatisfy { $0.runState == .started })
        XCTAssertTrue(services.logStore.events.map(\.kind).contains(.appStarted))

        services.stopAll()
        XCTAssertTrue(services.lifecycleComponents.allSatisfy { $0.runState == .stopped })
        XCTAssertTrue(services.logStore.events.map(\.kind).contains(.appStopped))
    }
}

#else
#error("This toolchain does not provide Testing or XCTest. Run `swift run AgentWakeCoreChecks` for portable checks.")
#endif

#if canImport(Testing) || canImport(XCTest)
private func makeTemporaryPaths() throws -> AgentWakePaths {
    let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("cs-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return AgentWakePaths(applicationSupportDirectory: url)
}
#endif
