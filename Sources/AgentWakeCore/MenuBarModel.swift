import Foundation

public enum MenuBarItemKind: Equatable, Sendable {
    case status
    case diagnostic
    case protectDetectedSessions
    case closedLidEnable
    case closedLidDisable
    case integrationStatus(String)
    case refreshStatus
    case repairIntegrations
    case settings
    case quit
}

public struct MenuBarItem: Equatable, Sendable {
    public let title: String
    public let detail: String?
    public let isEnabled: Bool
    public let kind: MenuBarItemKind

    public init(
        title: String,
        detail: String? = nil,
        isEnabled: Bool,
        kind: MenuBarItemKind
    ) {
        self.title = title
        self.detail = detail
        self.isEnabled = isEnabled
        self.kind = kind
    }
}

public struct MenuBarSnapshot: Equatable, Sendable {
    public let currentState: AgentWakeState
    public let statusItemTitle: String
    public let items: [MenuBarItem]

    public init(
        currentState: AgentWakeState,
        statusItemTitle: String,
        items: [MenuBarItem]
    ) {
        self.currentState = currentState
        self.statusItemTitle = statusItemTitle
        self.items = items
    }
}

public enum MenuBarModel {
    public static func snapshot(
        currentState: AgentWakeState,
        sessionSummary: String? = nil,
        closedLidModeStatus: String = ClosedLidModeAvailability.currentStatus.title,
        closedLidModeDetail: String? = ClosedLidModeAvailability.currentStatus.settingsDetail,
        protectDetectedSessionsEnabled: Bool = false,
        enableClosedLidModeEnabled: Bool = true,
        disableClosedLidModeEnabled: Bool = true,
        integrationStatuses: [IntegrationStatusSnapshot] = []
    ) -> MenuBarSnapshot {
        var items = [
            MenuBarItem(
                title: "Current: \(currentState.menuTitle)",
                detail: currentState.placeholderDetail,
                isEnabled: false,
                kind: .status
            )
        ]

        if let sessionSummary, !sessionSummary.isEmpty {
            items.append(
                MenuBarItem(
                    title: sessionSummary,
                    isEnabled: false,
                    kind: .diagnostic
                )
            )
        }

        items.append(
            MenuBarItem(
                title: "Protect Detected Sessions",
                detail: "Manually protects currently seen agent processes until they exit.",
                isEnabled: protectDetectedSessionsEnabled,
                kind: .protectDetectedSessions
            )
        )

        items.append(
            MenuBarItem(
                title: closedLidModeStatus,
                detail: closedLidModeDetail,
                isEnabled: false,
                kind: .diagnostic
            )
        )

        items += [
            MenuBarItem(
                title: "Enable Closed-Lid Mode",
                detail: "Requires macOS administrator approval.",
                isEnabled: enableClosedLidModeEnabled,
                kind: .closedLidEnable
            ),
            MenuBarItem(
                title: "Disable Closed-Lid Mode",
                detail: "Restores only AgentWake-owned closed-lid state.",
                isEnabled: disableClosedLidModeEnabled,
                kind: .closedLidDisable
            )
        ]

        items += integrationStatuses.map { snapshot in
            let title = "\(snapshot.displayName): \(snapshot.status.displayTitle)"
            let detail = snapshot.failureReason ?? snapshot.settingsFile
            return MenuBarItem(
                title: title,
                detail: detail,
                isEnabled: false,
                kind: .integrationStatus(snapshot.agentID)
            )
        }

        items += [
            MenuBarItem(
                title: "Refresh Status",
                isEnabled: true,
                kind: .refreshStatus
            ),
            MenuBarItem(
                title: "Repair Integrations...",
                isEnabled: true,
                kind: .repairIntegrations
            ),
            MenuBarItem(
                title: "Settings...",
                isEnabled: true,
                kind: .settings
            ),
            MenuBarItem(
                title: "Quit AgentWake",
                isEnabled: true,
                kind: .quit
            )
        ]

        return MenuBarSnapshot(
            currentState: currentState,
            statusItemTitle: currentState.statusItemTitle,
            items: items
        )
    }
}

public extension IntegrationInstallStatus {
    var displayTitle: String {
        switch self {
        case .notInstalled:
            "Not installed"
        case .installed:
            "Installed"
        case .failed:
            "Needs repair"
        case .degraded:
            "Degraded"
        case .removed:
            "Removed"
        }
    }
}
