import Foundation

#if canImport(Testing)
import Testing

struct IssueNineCoveragePlanTests {
    @Test func unitCoveragePlanRegistersEveryIssueNineRequirement() {
        #expect(coverageIDs(in: .unit) == [
            "session-transition-matrix",
            "pid-reuse-restart-dedupe",
            "out-of-order-hook-events",
            "grace-reset-rules",
            "manual-override-precedence",
            "safety-transition-matrix",
            "settings-migration-recovery",
            "export-redaction-exclusion"
        ])
    }

    @Test func contractCoveragePlanRegistersEveryIssueNineRequirement() {
        #expect(coverageIDs(in: .contract) == [
            "adapter-redaction",
            "adapter-no-op-when-not-running",
            "endpoint-auth-replay-rate-limit",
            "endpoint-peer-pid-identity",
            "config-patcher-fixtures",
            "config-merge-preserves-user-config",
            "owned-block-removal",
            "cli-command-behavior"
        ])
    }

    @Test func powerCoveragePlanRegistersAutomatedAndManualRequirements() {
        #expect(coverageIDs(in: .powerSnapshot) == [
            "pmset-assertions-snapshot",
            "pmset-custom-snapshot",
            "helper-auth-failure-artifacts",
            "helper-app-disagreement-reconciliation"
        ])
        #expect(coverageIDs(in: .manualHardware) == [
            "ac-lid-close",
            "battery-lid-close",
            "reboot-while-held",
            "app-crash-while-held",
            "helper-crash-restart",
            "helper-upgrade-mid-hold",
            "concurrent-power-change"
        ])
    }

    @Test func everyPlannedRequirementHasAnExplicitStatus() {
        #expect(issueNineCoveragePlan.allSatisfy { !$0.status.rawValue.isEmpty })
    }
}

#elseif canImport(XCTest)
import XCTest

final class IssueNineCoveragePlanTests: XCTestCase {
    func testUnitCoveragePlanRegistersEveryIssueNineRequirement() {
        XCTAssertEqual(coverageIDs(in: .unit), [
            "session-transition-matrix",
            "pid-reuse-restart-dedupe",
            "out-of-order-hook-events",
            "grace-reset-rules",
            "manual-override-precedence",
            "safety-transition-matrix",
            "settings-migration-recovery",
            "export-redaction-exclusion"
        ])
    }

    func testContractCoveragePlanRegistersEveryIssueNineRequirement() {
        XCTAssertEqual(coverageIDs(in: .contract), [
            "adapter-redaction",
            "adapter-no-op-when-not-running",
            "endpoint-auth-replay-rate-limit",
            "endpoint-peer-pid-identity",
            "config-patcher-fixtures",
            "config-merge-preserves-user-config",
            "owned-block-removal",
            "cli-command-behavior"
        ])
    }

    func testPowerCoveragePlanRegistersAutomatedAndManualRequirements() {
        XCTAssertEqual(coverageIDs(in: .powerSnapshot), [
            "pmset-assertions-snapshot",
            "pmset-custom-snapshot",
            "helper-auth-failure-artifacts",
            "helper-app-disagreement-reconciliation"
        ])
        XCTAssertEqual(coverageIDs(in: .manualHardware), [
            "ac-lid-close",
            "battery-lid-close",
            "reboot-while-held",
            "app-crash-while-held",
            "helper-crash-restart",
            "helper-upgrade-mid-hold",
            "concurrent-power-change"
        ])
    }

    func testEveryPlannedRequirementHasAnExplicitStatus() {
        XCTAssertTrue(issueNineCoveragePlan.allSatisfy { !$0.status.rawValue.isEmpty })
    }
}

#else
#error("This toolchain does not provide Testing or XCTest. Run `swift run ClawShellCoreChecks` for portable checks.")
#endif

#if canImport(Testing) || canImport(XCTest)
private struct CoverageRequirement: Equatable {
    let id: String
    let area: CoverageArea
    let status: CoverageStatus
}

private enum CoverageArea: Equatable {
    case unit
    case contract
    case powerSnapshot
    case manualHardware
}

private enum CoverageStatus: String, Equatable {
    case automated
    case fixtureSlot
    case pendingImplementation
    case manualChecklist
}

private let issueNineCoveragePlan: [CoverageRequirement] = [
    CoverageRequirement(id: "session-transition-matrix", area: .unit, status: .automated),
    CoverageRequirement(id: "pid-reuse-restart-dedupe", area: .unit, status: .automated),
    CoverageRequirement(id: "out-of-order-hook-events", area: .unit, status: .automated),
    CoverageRequirement(id: "grace-reset-rules", area: .unit, status: .automated),
    CoverageRequirement(id: "manual-override-precedence", area: .unit, status: .automated),
    CoverageRequirement(id: "safety-transition-matrix", area: .unit, status: .automated),
    CoverageRequirement(id: "settings-migration-recovery", area: .unit, status: .automated),
    CoverageRequirement(id: "export-redaction-exclusion", area: .unit, status: .automated),
    CoverageRequirement(id: "adapter-redaction", area: .contract, status: .automated),
    CoverageRequirement(id: "adapter-no-op-when-not-running", area: .contract, status: .automated),
    CoverageRequirement(id: "endpoint-auth-replay-rate-limit", area: .contract, status: .automated),
    CoverageRequirement(id: "endpoint-peer-pid-identity", area: .contract, status: .automated),
    CoverageRequirement(id: "config-patcher-fixtures", area: .contract, status: .automated),
    CoverageRequirement(id: "config-merge-preserves-user-config", area: .contract, status: .automated),
    CoverageRequirement(id: "owned-block-removal", area: .contract, status: .automated),
    CoverageRequirement(id: "cli-command-behavior", area: .contract, status: .automated),
    CoverageRequirement(id: "pmset-assertions-snapshot", area: .powerSnapshot, status: .automated),
    CoverageRequirement(id: "pmset-custom-snapshot", area: .powerSnapshot, status: .automated),
    CoverageRequirement(id: "helper-auth-failure-artifacts", area: .powerSnapshot, status: .automated),
    CoverageRequirement(id: "helper-app-disagreement-reconciliation", area: .powerSnapshot, status: .pendingImplementation),
    CoverageRequirement(id: "ac-lid-close", area: .manualHardware, status: .manualChecklist),
    CoverageRequirement(id: "battery-lid-close", area: .manualHardware, status: .manualChecklist),
    CoverageRequirement(id: "reboot-while-held", area: .manualHardware, status: .manualChecklist),
    CoverageRequirement(id: "app-crash-while-held", area: .manualHardware, status: .manualChecklist),
    CoverageRequirement(id: "helper-crash-restart", area: .manualHardware, status: .manualChecklist),
    CoverageRequirement(id: "helper-upgrade-mid-hold", area: .manualHardware, status: .manualChecklist),
    CoverageRequirement(id: "concurrent-power-change", area: .manualHardware, status: .manualChecklist)
]

private func coverageIDs(in area: CoverageArea) -> [String] {
    issueNineCoveragePlan
        .filter { $0.area == area }
        .map(\.id)
}
#endif
