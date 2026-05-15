import Foundation

public enum AgentWakeState: String, CaseIterable, Equatable, Identifiable, Sendable {
    case idle
    case active
    case bagMode
    case paused

    public var id: String {
        rawValue
    }

    public var menuTitle: String {
        switch self {
        case .idle:
            "Idle"
        case .active:
            "Protecting"
        case .bagMode:
            BagModeAvailability.unavailableTitle
        case .paused:
            "Paused"
        }
    }

    public var statusItemTitle: String {
        switch self {
        case .idle, .active, .bagMode, .paused:
            "AgentWake"
        }
    }

    public var placeholderDetail: String {
        switch self {
        case .idle:
            "No agent session seen"
        case .active:
            "Keeping this Mac awake for agent work"
        case .bagMode:
            BagModeAvailability.settingsDetail
        case .paused:
            "Sleep protection paused"
        }
    }

    public static func derived(from holdState: AgentAggregateHoldState) -> AgentWakeState {
        if holdState.isPaused || holdState.isSafetyCutoffActive {
            return .paused
        }

        return holdState.shouldHold ? .active : .idle
    }
}
