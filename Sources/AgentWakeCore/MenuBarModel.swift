import Foundation

public enum MenuBarItemKind: Equatable, Sendable {
    case status
    case diagnostic
    case separator
    case protectDetectedSessions
    case releaseProtection
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
    public let statusItemAccessibilityTitle: String
    public let statusItemIcon: MenuBarStatusIcon
    public let items: [MenuBarItem]

    public init(
        currentState: AgentWakeState,
        statusItemAccessibilityTitle: String,
        statusItemIcon: MenuBarStatusIcon,
        items: [MenuBarItem]
    ) {
        self.currentState = currentState
        self.statusItemAccessibilityTitle = statusItemAccessibilityTitle
        self.statusItemIcon = statusItemIcon
        self.items = items
    }
}

public enum MenuBarStatusTint: String, Equatable, Sendable {
    case secondary
    case accent
    case warning
    case unknown
}

public struct MenuBarStatusIcon: Equatable, Sendable {
    public let baseSystemImageName: String
    public let overlaySystemImageName: String?
    public let tint: MenuBarStatusTint
    public let accessibilityDescription: String

    public init(
        baseSystemImageName: String,
        overlaySystemImageName: String? = nil,
        tint: MenuBarStatusTint,
        accessibilityDescription: String
    ) {
        self.baseSystemImageName = baseSystemImageName
        self.overlaySystemImageName = overlaySystemImageName
        self.tint = tint
        self.accessibilityDescription = accessibilityDescription
    }
}

public enum MenuBarModel {
    public static func snapshot(
        currentState: AgentWakeState,
        sessionSummary: String? = nil,
        closedLidModeStatus: String = ClosedLidModeAvailability.currentStatus.title,
        closedLidModeDetail: String? = ClosedLidModeAvailability.currentStatus.settingsDetail,
        protectableDetectedSessionCount: Int = 0,
        enableClosedLidModeEnabled: Bool = true,
        disableClosedLidModeEnabled: Bool = false,
        showRefreshStatus: Bool = false,
        integrationStatuses: [IntegrationStatusSnapshot] = []
    ) -> MenuBarSnapshot {
        var items = [
            MenuBarItem(
                title: statusTitle(currentState: currentState, sessionSummary: sessionSummary),
                detail: currentState.placeholderDetail,
                isEnabled: false,
                kind: .status
            )
        ]

        if let sessionSummary, !sessionSummary.isEmpty, !statusIncludesSessionSummary(currentState: currentState, sessionSummary: sessionSummary) {
            items.append(
                MenuBarItem(
                    title: sessionSummary,
                    isEnabled: false,
                    kind: .diagnostic
                )
            )
        }

        if protectableDetectedSessionCount > 0 {
            items.append(
                MenuBarItem(
                    title: protectDetectedSessionsTitle(count: protectableDetectedSessionCount),
                    detail: protectDetectedSessionsDetail(count: protectableDetectedSessionCount),
                    isEnabled: true,
                    kind: .protectDetectedSessions
                )
            )
        }

        if currentState == .active {
            items.append(
                MenuBarItem(
                    title: "Stop Keeping Awake",
                    detail: "Lets the Mac sleep until new agent activity starts.",
                    isEnabled: true,
                    kind: .releaseProtection
                )
            )
        }

        items.append(separatorItem())

        items.append(
            MenuBarItem(
                title: closedLidStatusTitle(closedLidModeStatus),
                detail: closedLidModeDetail,
                isEnabled: false,
                kind: .diagnostic
            )
        )

        if disableClosedLidModeEnabled {
            items.append(
                MenuBarItem(
                    title: "Turn Off Lid-Closed Awake",
                    detail: "Restores only AgentWake-owned closed-lid state.",
                    isEnabled: true,
                    kind: .closedLidDisable
                )
            )
        } else if enableClosedLidModeEnabled {
            items.append(
                MenuBarItem(
                    title: "Turn On Lid-Closed Awake",
                    detail: "Prevents sleep when the lid closes. Requires macOS administrator approval.",
                    isEnabled: true,
                    kind: .closedLidEnable
                )
            )
        }

        let integrationIssues = integrationStatuses.filter { $0.status != .installed }
        if !integrationIssues.isEmpty {
            items.append(separatorItem())
            items += integrationIssues.map { snapshot in
                let title = "\(snapshot.displayName): \(snapshot.status.displayTitle)"
                let detail = snapshot.failureReason ?? snapshot.settingsFile
                return MenuBarItem(
                    title: title,
                    detail: detail,
                    isEnabled: false,
                    kind: .integrationStatus(snapshot.agentID)
                )
            }
            items.append(
                MenuBarItem(
                    title: "Reinstall agent hooks",
                    isEnabled: true,
                    kind: .repairIntegrations
                )
            )
        }

        if showRefreshStatus {
            items += [
                separatorItem(),
                MenuBarItem(
                    title: "Refresh",
                    detail: "Status has not updated recently.",
                    isEnabled: true,
                    kind: .refreshStatus
                )
            ]
        }

        items += [
            MenuBarItem(
                title: "Settings...",
                isEnabled: true,
                kind: .settings
            ),
            separatorItem(),
            MenuBarItem(
                title: "Quit AgentWake",
                isEnabled: true,
                kind: .quit
            )
        ]

        return MenuBarSnapshot(
            currentState: currentState,
            statusItemAccessibilityTitle: "AgentWake",
            statusItemIcon: statusItemIcon(currentState: currentState, closedLidModeStatus: closedLidModeStatus),
            items: items
        )
    }

    private static func statusItemIcon(currentState: AgentWakeState, closedLidModeStatus: String) -> MenuBarStatusIcon {
        switch currentState {
        case .idle:
            return MenuBarStatusIcon(
                baseSystemImageName: closedLidModeStatus == "Closed-Lid Mode enabled outside AgentWake" ? "moon" : "moon.fill",
                tint: closedLidModeStatus == "Closed-Lid Mode enabled outside AgentWake" ? .unknown : .secondary,
                accessibilityDescription: "Idle"
            )
        case .active:
            return MenuBarStatusIcon(
                baseSystemImageName: "bolt.fill",
                overlaySystemImageName: closedLidModeStatus == "Closed-Lid Mode enabled" ? "lock.fill" : nil,
                tint: .accent,
                accessibilityDescription: closedLidModeStatus == "Closed-Lid Mode enabled" ? "Keeping Mac awake with Lid-Closed Awake on" : "Keeping Mac awake"
            )
        case .bagMode:
            return MenuBarStatusIcon(
                baseSystemImageName: "moon",
                tint: .unknown,
                accessibilityDescription: ClosedLidModeAvailability.unavailableTitle
            )
        case .paused:
            return MenuBarStatusIcon(
                baseSystemImageName: "exclamationmark.triangle.fill",
                tint: .warning,
                accessibilityDescription: "Sleep protection paused or safety cutoff active"
            )
        }
    }

    private static func statusTitle(currentState: AgentWakeState, sessionSummary: String?) -> String {
        if currentState == .active,
           let sessionSummary,
           statusIncludesSessionSummary(currentState: currentState, sessionSummary: sessionSummary) {
            return sessionSummary
        }

        return currentState.menuTitle
    }

    private static func protectDetectedSessionsTitle(count: Int) -> String {
        return count == 1 ? "Keep 1 session awake" : "Keep \(count) sessions awake"
    }

    private static func protectDetectedSessionsDetail(count: Int) -> String {
        return "Keeps detected sessions awake until they exit."
    }

    private static func closedLidStatusTitle(_ status: String) -> String {
        switch status {
        case "Closed-Lid Mode off":
            return "Lid-Closed Awake: Off"
        case "Closed-Lid Mode enabled", "Closed-Lid Mode already enabled":
            return "Lid-Closed Awake: On"
        case "Closed-Lid Mode ownership pending":
            return "Lid-Closed Awake: Finishing Setup"
        case "Closed-Lid Mode enabled outside AgentWake":
            return "Lid-Closed Awake: On Outside AgentWake"
        case "Closed-Lid Mode status unknown":
            return "Lid-Closed Awake: Unknown"
        default:
            return status
        }
    }

    private static func statusIncludesSessionSummary(currentState: AgentWakeState, sessionSummary: String?) -> Bool {
        currentState == .active && sessionSummary?.contains("Keeping awake") == true
    }

    private static func separatorItem() -> MenuBarItem {
        MenuBarItem(title: "", isEnabled: false, kind: .separator)
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
