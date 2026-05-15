import Foundation

#if canImport(Testing)
import Testing
@testable import ClawShellCore

struct MenuBarModelTests {
    @Test func snapshotIncludesRuntimeDiagnostics() {
        let snapshot = MenuBarModel.snapshot(
            currentState: .idle,
            sessionSummary: "Sessions: none detected",
            integrationStatuses: [
                IntegrationStatusSnapshot(
                    agentID: "claude-code",
                    displayName: "Claude Code",
                    status: .installed
                )
            ]
        )

        #expect(snapshot.items.map(\.title).contains("Sessions: none detected"))
        #expect(snapshot.items.map(\.title).contains(BagModeAvailability.unavailableTitle))
        #expect(snapshot.items.map(\.title).contains("Claude Code: Installed"))
        #expect(snapshot.items.map(\.title).contains("Refresh Status"))
        #expect(snapshot.items.map(\.title).contains("Repair Integrations..."))
    }

    @Test func snapshotNamesTheCurrentState() {
        let snapshot = MenuBarModel.snapshot(currentState: .bagMode)

        #expect(snapshot.currentState == .bagMode)
        #expect(snapshot.statusItemTitle == "ClawShell")
        #expect(snapshot.items.first?.title == "Current: \(BagModeAvailability.unavailableTitle)")
        #expect(snapshot.items.first?.detail == BagModeAvailability.settingsDetail)
    }

    @Test func stateDerivesFromHoldState() {
        #expect(ClawShellState.derived(from: AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])) == .idle)
        #expect(ClawShellState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()])) == .active)
        #expect(ClawShellState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [], isPaused: true)) == .paused)
        #expect(ClawShellState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [], isSafetyCutoffActive: true)) == .paused)
    }

    @Test func lifecycleComponentsCanStartAndStopTogether() throws {
        let paths = try makeTemporaryPaths()
        let services = ClawShellServices(paths: paths)

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
@testable import ClawShellCore

final class MenuBarModelTests: XCTestCase {
    func testSnapshotIncludesRuntimeDiagnostics() {
        let snapshot = MenuBarModel.snapshot(
            currentState: .idle,
            sessionSummary: "Sessions: none detected",
            integrationStatuses: [
                IntegrationStatusSnapshot(
                    agentID: "claude-code",
                    displayName: "Claude Code",
                    status: .installed
                )
            ]
        )

        XCTAssertTrue(snapshot.items.map(\.title).contains("Sessions: none detected"))
        XCTAssertTrue(snapshot.items.map(\.title).contains(BagModeAvailability.unavailableTitle))
        XCTAssertTrue(snapshot.items.map(\.title).contains("Claude Code: Installed"))
        XCTAssertTrue(snapshot.items.map(\.title).contains("Refresh Status"))
        XCTAssertTrue(snapshot.items.map(\.title).contains("Repair Integrations..."))
    }

    func testSnapshotNamesTheCurrentState() {
        let snapshot = MenuBarModel.snapshot(currentState: .bagMode)

        XCTAssertEqual(snapshot.currentState, .bagMode)
        XCTAssertEqual(snapshot.statusItemTitle, "ClawShell")
        XCTAssertEqual(snapshot.items.first?.title, "Current: \(BagModeAvailability.unavailableTitle)")
        XCTAssertEqual(snapshot.items.first?.detail, BagModeAvailability.settingsDetail)
    }

    func testStateDerivesFromHoldState() {
        XCTAssertEqual(ClawShellState.derived(from: AgentAggregateHoldState(shouldHold: false, heldSessionIDs: [])), .idle)
        XCTAssertEqual(ClawShellState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [UUID()])), .active)
        XCTAssertEqual(ClawShellState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [], isPaused: true)), .paused)
        XCTAssertEqual(ClawShellState.derived(from: AgentAggregateHoldState(shouldHold: true, heldSessionIDs: [], isSafetyCutoffActive: true)), .paused)
    }

    func testLifecycleComponentsCanStartAndStopTogether() throws {
        let paths = try makeTemporaryPaths()
        let services = ClawShellServices(paths: paths)

        services.startAll()
        XCTAssertTrue(services.lifecycleComponents.allSatisfy { $0.runState == .started })
        XCTAssertTrue(services.logStore.events.map(\.kind).contains(.appStarted))

        services.stopAll()
        XCTAssertTrue(services.lifecycleComponents.allSatisfy { $0.runState == .stopped })
        XCTAssertTrue(services.logStore.events.map(\.kind).contains(.appStopped))
    }
}

#else
#error("This toolchain does not provide Testing or XCTest. Run `swift run ClawShellCoreChecks` for portable checks.")
#endif

#if canImport(Testing) || canImport(XCTest)
private func makeTemporaryPaths() throws -> ClawShellPaths {
    let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("cs-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return ClawShellPaths(applicationSupportDirectory: url)
}
#endif
