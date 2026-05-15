import Foundation

#if canImport(Testing)
import Testing

struct ContractHarnessTests {
    @Test func contractFixtureSlotsExist() throws {
        try assertFixtureSlotsExist()
    }
}

#elseif canImport(XCTest)
import XCTest

final class ContractHarnessTests: XCTestCase {
    func testContractFixtureSlotsExist() throws {
        try assertFixtureSlotsExist()
    }
}

#else
#error("This toolchain does not provide Testing or XCTest. Run `swift run AgentWakeCoreChecks` for portable checks.")
#endif

#if canImport(Testing) || canImport(XCTest)
private func assertFixtureSlotsExist() throws {
    for name in [
        "adapters",
        "cli",
        "config-patchers",
        "control-server",
        "power"
    ] {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        guard let url else {
            throw ContractHarnessFailure("Missing contract fixture slot: \(name)")
        }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw ContractHarnessFailure("Contract fixture slot is not a directory: \(name)")
        }
    }
}

private struct ContractHarnessFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
