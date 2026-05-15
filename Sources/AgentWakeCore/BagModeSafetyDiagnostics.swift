import Foundation

public struct BagModeSafetyDiagnostic: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var recoveryAction: String?

    public init(title: String, detail: String, recoveryAction: String? = nil) {
        self.title = title
        self.detail = detail
        self.recoveryAction = recoveryAction
    }

    public static func userFacing(for decision: BagModeSafetyDecision) -> BagModeSafetyDiagnostic? {
        switch decision.action {
        case .allow:
            return nil
        case .warn:
            return BagModeSafetyDiagnostic(
                title: "Closed-Lid Mode warning: thermal conditions are elevated",
                detail: "AgentWake can keep protecting this Mac, but current thermal signals need attention.",
                recoveryAction: "Keep the Mac ventilated and watch for a cutoff if temperature keeps rising."
            )
        case .failClosedBeforeArming, .releaseIfArmed:
            guard let reason = decision.state.cutoffReason else {
                return BagModeSafetyDiagnostic(
                    title: titlePrefix(for: decision.action) + "safety state unavailable",
                    detail: "AgentWake could not confirm that Closed-Lid Mode is safe to use right now.",
                    recoveryAction: "Try again after the safety state refreshes."
                )
            }

            return BagModeSafetyDiagnostic(
                title: titlePrefix(for: decision.action) + reason.titleFragment,
                detail: reason.detail,
                recoveryAction: reason.recoveryAction
            )
        }
    }

    private static func titlePrefix(for action: BagModeSafetyAction) -> String {
        switch action {
        case .releaseIfArmed:
            return "Closed-Lid Mode released: "
        case .failClosedBeforeArming:
            return "Closed-Lid Mode unavailable: "
        case .allow, .warn:
            return ""
        }
    }
}

private extension BagModeSafetyCutoffReason {
    var titleFragment: String {
        switch self {
        case .temperature:
            return "temperature cutoff reached"
        case .battery:
            return "battery is below the floor"
        case .staleSensor:
            return "temperature reading is stale"
        case .unavailableSensor:
            return "temperature provider is unavailable"
        case .permissionDenied:
            return "temperature provider needs permission"
        case .parseFailed:
            return "temperature reading could not be parsed"
        case .helperCrashed:
            return "helper stopped unexpectedly"
        case .unsupportedHardware:
            return "hardware is unsupported"
        case .timedOut:
            return "temperature provider timed out"
        case .coverageInsufficient:
            return "closed-bag coverage is unproven"
        case .batteryUnavailable:
            return "battery reading is unavailable"
        case .batteryInvalid:
            return "battery reading is invalid"
        }
    }

    var detail: String {
        switch self {
        case .temperature:
            return "The temperature cutoff was reached, so AgentWake will not keep Closed-Lid Mode armed."
        case .battery:
            return "Battery is at or below the configured floor, so AgentWake will not keep Closed-Lid Mode armed."
        case .staleSensor:
            return "The last temperature sample is too old to trust for closed-lid operation."
        case .unavailableSensor:
            return "AgentWake cannot read the temperature provider required for Closed-Lid Mode."
        case .permissionDenied:
            return "macOS denied access to the temperature provider required for Closed-Lid Mode."
        case .parseFailed:
            return "AgentWake received provider output but could not turn it into a trusted temperature reading."
        case .helperCrashed:
            return "The helper process stopped before AgentWake could confirm the Closed-Lid Mode safety state."
        case .unsupportedHardware:
            return "This Mac does not expose the validated signals AgentWake requires for Closed-Lid Mode."
        case .timedOut:
            return "The temperature provider did not respond within the required timeout."
        case .coverageInsufficient:
            return "The available temperature signal has not been proven to cover closed-bag thermal risk."
        case .batteryUnavailable:
            return "AgentWake cannot read the battery level required for Closed-Lid Mode."
        case .batteryInvalid:
            return "The battery level reported to AgentWake is outside the expected 0 to 100 percent range."
        }
    }

    var recoveryAction: String {
        switch self {
        case .temperature:
            return "Let the Mac cool before re-arming Closed-Lid Mode."
        case .battery:
            return "Charge the Mac above the configured floor before using Closed-Lid Mode."
        case .staleSensor, .unavailableSensor, .permissionDenied, .parseFailed, .helperCrashed, .timedOut:
            return "Try again after the provider recovers, or run helper repair when helper support is installed."
        case .unsupportedHardware:
            return "Use normal sleep protection on this Mac until Closed-Lid Mode support is validated."
        case .coverageInsufficient:
            return "Use normal sleep prevention until closed-bag thermal coverage is validated."
        case .batteryUnavailable, .batteryInvalid:
            return "Try again after macOS reports a valid battery level."
        }
    }
}
