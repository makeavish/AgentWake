import Foundation
import IOKit.pwr_mgt

public enum PowerAssertionType: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case preventUserIdleSystemSleep
    case preventSystemSleep
    case preventDiskIdle
    case preventDisplaySleep

    public var iopmAssertionType: String {
        switch self {
        case .preventUserIdleSystemSleep:
            kIOPMAssertionTypePreventUserIdleSystemSleep
        case .preventSystemSleep:
            kIOPMAssertionTypePreventSystemSleep
        case .preventDiskIdle:
            "PreventDiskIdle"
        case .preventDisplaySleep:
            kIOPMAssertionTypeNoDisplaySleep
        }
    }

    public var displayName: String {
        switch self {
        case .preventUserIdleSystemSleep:
            "Prevent user idle system sleep"
        case .preventSystemSleep:
            "Prevent system sleep"
        case .preventDiskIdle:
            "Prevent disk idle"
        case .preventDisplaySleep:
            "Prevent display sleep"
        }
    }
}

public struct PowerAssertionID: RawRepresentable, Equatable, Hashable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public struct NormalPowerAssertionPolicy: Equatable, Sendable {
    public var assertionTypes: [PowerAssertionType]
    public var reason: String

    public init(
        assertionTypes: [PowerAssertionType] = Self.validatedDefaultAssertionTypes,
        reason: String = "AgentWake is protecting agent work from sleep"
    ) {
        self.assertionTypes = assertionTypes
        self.reason = reason
    }

    public static let validatedDefaultAssertionTypes: [PowerAssertionType] = [
        .preventUserIdleSystemSleep
    ]

    public static let validationCandidateAssertionTypes: [PowerAssertionType] = [
        .preventUserIdleSystemSleep,
        .preventSystemSleep,
        .preventDiskIdle
    ]

    public static let validatedDefault = NormalPowerAssertionPolicy()
}

public enum PowerAssertionError: Error, Equatable, LocalizedError {
    case createFailed(type: PowerAssertionType, code: Int32)
    case releaseFailed(id: PowerAssertionID, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let type, let code):
            "Failed to create \(type.displayName) assertion (IOKit code \(code))."
        case .releaseFailed(let id, let code):
            "Failed to release power assertion \(id.rawValue) (IOKit code \(code))."
        }
    }
}

public protocol PowerAssertionControlling {
    func createAssertion(type: PowerAssertionType, reason: String) throws -> PowerAssertionID
    func releaseAssertion(_ id: PowerAssertionID) throws
}

public struct IOPMPowerAssertionController: PowerAssertionControlling {
    public init() {}

    public func createAssertion(type: PowerAssertionType, reason: String) throws -> PowerAssertionID {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type.iopmAssertionType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )

        guard result == kIOReturnSuccess else {
            throw PowerAssertionError.createFailed(type: type, code: result)
        }

        return PowerAssertionID(rawValue: assertionID)
    }

    public func releaseAssertion(_ id: PowerAssertionID) throws {
        let result = IOPMAssertionRelease(IOPMAssertionID(id.rawValue))

        guard result == kIOReturnSuccess else {
            throw PowerAssertionError.releaseFailed(id: id, code: result)
        }
    }
}
