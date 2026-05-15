import Foundation

public enum ClosedLidModeAvailability {
    public static let unavailableTitle = "Closed-Lid Mode unavailable"

    public static let unavailableDetail = "Helper lifecycle and temperature-provider validation are incomplete."

    public static let settingsDetail = "Closed-Lid Mode is disabled until helper lifecycle and live temperature-provider validation are complete."

    public static func helperCommandMessage(_ command: String) -> String {
        switch command {
        case "status":
            "Closed-Lid Mode helper status unavailable: \(unavailableDetail)"
        default:
            "Closed-Lid Mode \(command) unavailable: \(unavailableDetail)"
        }
    }
}

@available(*, deprecated, renamed: "ClosedLidModeAvailability")
public typealias BagModeAvailability = ClosedLidModeAvailability
