import Foundation

#if canImport(Testing)
import Testing
@testable import AgentWakeCore

struct MenuBarModelTests {
    @Test func snapshotIncludesRuntimeDiagnostics() {
        let snapshot = MenuBarModel.snapshot(
            currentState: .idle,
            sessionSummary: "No sessions",
            integrationStatuses: [
                IntegrationStatusSnapshot(
                    agentID: "claude-code",
                    displayName: "Claude Code",
                    status: .installed
                )
            ]
        )

        #expect(snapshot.items.map(\.title).contains("No sessions"))
        #expect(snapshot.items.map(\.title).contains(ClosedLidModeAvailability.unavailableTitle))
        #expect(!snapshot.items.map(\.title).contains("Keep Awake"))
        #expect(snapshot.items.map(\.title).contains("Turn On Lid-Closed Awake"))
        #expect(snapshot.items.map(\.title).contains("Refresh"))
        #expect(!snapshot.items.map(\.title).contains("Claude Code: Installed"))
        #expect(!snapshot.items.map(\.title).contains("Repair Integrations..."))

        let protectableSnapshot = MenuBarModel.snapshot(
            currentState: .idle,
            protectableDetectedSessionCount: 2
        )
        #expect(protectableSnapshot.items.contains {
            $0.title == "Keep 2 Awake" && $0.isEnabled
        })

        let activeSnapshot = MenuBarModel.snapshot(
            currentState: .active,
            sessionSummary: "1 keeping awake, 2 found"
        )
        #expect(activeSnapshot.items.first?.title == "Status: 1 keeping awake, 2 found")
        #expect(activeSnapshot.items.contains {
            $0.title == "Stop Keeping Awake" && $0.isEnabled
        })

        let degradedSnapshot = MenuBarModel.snapshot(
            currentState: .idle,
            integrationStatuses: [
                IntegrationStatusSnapshot(
                    agentID: "codex-cli",
                    displayName: "Codex CLI",
                    status: .failed
                )
            ]
        )
        #expect(degradedSnapshot.items.map(\.title).contains("Codex CLI: Needs repair"))
        #expect(degradedSnapshot.items.map(\.title).contains("Repair Integrations..."))
    }

    @Test func snapshotNamesTheCurrentState() {
        let snapshot = MenuBarModel.snapshot(currentState: .bagMode)

        #expect(snapshot.currentState == .bagMode)
        #expect(snapshot.statusItemTitle == "AgentWake")
        #expect(snapshot.items.first?.title == "Status: \(ClosedLidModeAvailability.unavailableTitle)")
        #expect(snapshot.items.first?.detail == ClosedLidModeAvailability.settingsDetail)
    }

    @Test func closedLidModeStatusNamesPendingGates() {
        let status = ClosedLidModeStatus(pendingGates: [.helperLifecycle, .temperatureProvider])

        #expect(!status.isAvailable)
        #expect(status.title == "Closed-Lid Mode unavailable")
        #expect(status.summary == "Blocked by 2 checks.")
        #expect(status.settingsDetail.contains("Helper lifecycle"))
        #expect(status.commandMessage("status").contains("- Temperature provider:"))
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
            sessionSummary: "No sessions",
            integrationStatuses: [
                IntegrationStatusSnapshot(
                    agentID: "claude-code",
                    displayName: "Claude Code",
                    status: .installed
                )
            ]
        )

        XCTAssertTrue(snapshot.items.map(\.title).contains("No sessions"))
        XCTAssertTrue(snapshot.items.map(\.title).contains(ClosedLidModeAvailability.unavailableTitle))
        XCTAssertFalse(snapshot.items.map(\.title).contains("Keep Awake"))
        XCTAssertTrue(snapshot.items.map(\.title).contains("Turn On Lid-Closed Awake"))
        XCTAssertTrue(snapshot.items.map(\.title).contains("Refresh"))
        XCTAssertFalse(snapshot.items.map(\.title).contains("Claude Code: Installed"))
        XCTAssertFalse(snapshot.items.map(\.title).contains("Repair Integrations..."))

        let protectableSnapshot = MenuBarModel.snapshot(
            currentState: .idle,
            protectableDetectedSessionCount: 2
        )
        XCTAssertTrue(protectableSnapshot.items.contains {
            $0.title == "Keep 2 Awake" && $0.isEnabled
        })

        let activeSnapshot = MenuBarModel.snapshot(
            currentState: .active,
            sessionSummary: "1 keeping awake, 2 found"
        )
        XCTAssertEqual(activeSnapshot.items.first?.title, "Status: 1 keeping awake, 2 found")
        XCTAssertTrue(activeSnapshot.items.contains {
            $0.title == "Stop Keeping Awake" && $0.isEnabled
        })

        let degradedSnapshot = MenuBarModel.snapshot(
            currentState: .idle,
            integrationStatuses: [
                IntegrationStatusSnapshot(
                    agentID: "codex-cli",
                    displayName: "Codex CLI",
                    status: .failed
                )
            ]
        )
        XCTAssertTrue(degradedSnapshot.items.map(\.title).contains("Codex CLI: Needs repair"))
        XCTAssertTrue(degradedSnapshot.items.map(\.title).contains("Repair Integrations..."))
    }

    func testSnapshotNamesTheCurrentState() {
        let snapshot = MenuBarModel.snapshot(currentState: .bagMode)

        XCTAssertEqual(snapshot.currentState, .bagMode)
        XCTAssertEqual(snapshot.statusItemTitle, "AgentWake")
        XCTAssertEqual(snapshot.items.first?.title, "Status: \(ClosedLidModeAvailability.unavailableTitle)")
        XCTAssertEqual(snapshot.items.first?.detail, ClosedLidModeAvailability.settingsDetail)
    }

    func testClosedLidModeStatusNamesPendingGates() {
        let status = ClosedLidModeStatus(pendingGates: [.helperLifecycle, .temperatureProvider])

        XCTAssertFalse(status.isAvailable)
        XCTAssertEqual(status.title, "Closed-Lid Mode unavailable")
        XCTAssertEqual(status.summary, "Blocked by 2 checks.")
        XCTAssertTrue(status.settingsDetail.contains("Helper lifecycle"))
        XCTAssertTrue(status.commandMessage("status").contains("- Temperature provider:"))
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
