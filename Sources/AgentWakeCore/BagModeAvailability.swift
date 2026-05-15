import Foundation

public enum BagModeAvailability {
    public static let unavailableTitle = "Closed-Lid Mode unavailable"

    public static let unavailableDetail = "Helper lifecycle and temperature-provider validation are incomplete."

    public static let settingsDetail = "Closed-Lid Mode is disabled until helper lifecycle and live temperature-provider validation are complete."

    public static func helperCommandMessage(_ command: String) -> String {
        "Helper \(command) unavailable: \(unavailableDetail)"
    }
}
