import Foundation

#if canImport(Testing)
import Testing
@testable import ClawShellCore

struct MenuBarModelTests {
    @Test func snapshotIncludesAllPlaceholderStates() {
        let snapshot = MenuBarModel.snapshot(currentState: .idle)

        let placeholderStates = snapshot.items.compactMap { item -> ClawShellState? in
            guard case let .placeholderState(state) = item.kind else {
                return nil
            }

            return state
        }

        #expect(placeholderStates == ClawShellState.allCases)
        #expect(placeholderTitles(in: snapshot) == ["Idle", "Active", "Bag Mode", "Paused"])
    }

    @Test func snapshotNamesTheCurrentState() {
        let snapshot = MenuBarModel.snapshot(currentState: .bagMode)

        #expect(snapshot.currentState == .bagMode)
        #expect(snapshot.statusItemTitle == "ClawShell Bag")
        #expect(snapshot.items.first?.title == "Current: Bag Mode")
        #expect(snapshot.items.first?.detail == "Closed-lid guarded mode")
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
    func testSnapshotIncludesAllPlaceholderStates() {
        let snapshot = MenuBarModel.snapshot(currentState: .idle)

        let placeholderStates = snapshot.items.compactMap { item -> ClawShellState? in
            guard case let .placeholderState(state) = item.kind else {
                return nil
            }

            return state
        }

        XCTAssertEqual(placeholderStates, ClawShellState.allCases)
        XCTAssertEqual(placeholderTitles(in: snapshot), ["Idle", "Active", "Bag Mode", "Paused"])
    }

    func testSnapshotNamesTheCurrentState() {
        let snapshot = MenuBarModel.snapshot(currentState: .bagMode)

        XCTAssertEqual(snapshot.currentState, .bagMode)
        XCTAssertEqual(snapshot.statusItemTitle, "ClawShell Bag")
        XCTAssertEqual(snapshot.items.first?.title, "Current: Bag Mode")
        XCTAssertEqual(snapshot.items.first?.detail, "Closed-lid guarded mode")
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
import ClawShellCore

func packageHasAStandardTestTarget() {
    _ = MenuBarModel.snapshot(currentState: .idle)
}
#endif

private func placeholderTitles(in snapshot: MenuBarSnapshot) -> [String] {
    snapshot.items.compactMap { item -> String? in
        guard case .placeholderState = item.kind else {
            return nil
        }

        return item.title
    }
}

private func makeTemporaryPaths() throws -> ClawShellPaths {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClawShellTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return ClawShellPaths(applicationSupportDirectory: url)
}
