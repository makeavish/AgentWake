import Foundation

public enum MenuBarItemKind: Equatable, Sendable {
    case status
    case diagnostic
    case separator
    case pauseProtection
    case resumeProtection
    case protectDetectedSessions
    case closedLidEnable
    case closedLidDisable
    case closedLidTakeOwnership
    case integrationStatus(String)
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
        closedLidStatus: ClosedLidStatus? = nil,
        closedLidModeDetail: String? = ClosedLidModeAvailability.currentStatus.settingsDetail,
        protectableDetectedSessionCount: Int = 0,
        enableClosedLidModeEnabled: Bool = true,
        disableClosedLidModeEnabled: Bool = false,
        takeClosedLidOwnershipEnabled: Bool = false,
        isSleepProtectionPaused: Bool = false,
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

        items.append(
            MenuBarItem(
                title: isSleepProtectionPaused ? "Resume Sleep Protection" : "Pause Sleep Protection",
                detail: isSleepProtectionPaused ? "Allows AgentWake to keep the Mac awake again." : "Lets the Mac sleep until you resume.",
                isEnabled: true,
                kind: isSleepProtectionPaused ? .resumeProtection : .pauseProtection
            )
        )

        items.append(separatorItem())

        items.append(
            MenuBarItem(
                title: closedLidStatusTitle(closedLidStatus),
                detail: closedLidStatusDetail(closedLidStatus) ?? closedLidModeDetail,
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
        } else if takeClosedLidOwnershipEnabled {
            items.append(
                MenuBarItem(
                    title: "Take Ownership...",
                    detail: "Use only if you want AgentWake to restore the current disabled-lid-sleep setting.",
                    isEnabled: true,
                    kind: .closedLidTakeOwnership
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
            statusItemIcon: statusItemIcon(currentState: currentState, closedLidStatus: closedLidStatus),
            items: items
        )
    }

    private static func statusItemIcon(currentState: AgentWakeState, closedLidStatus: ClosedLidStatus?) -> MenuBarStatusIcon {
        switch currentState {
        case .idle:
            return MenuBarStatusIcon(
                baseSystemImageName: closedLidStatus == .enabledByOther ? "moon" : "moon.fill",
                tint: closedLidStatus == .enabledByOther ? .unknown : .secondary,
                accessibilityDescription: "Idle"
            )
        case .active:
            return MenuBarStatusIcon(
                baseSystemImageName: "bolt.fill",
                overlaySystemImageName: closedLidStatus == .enabledByAgentWake ? "lock.fill" : nil,
                tint: .accent,
                accessibilityDescription: closedLidStatus == .enabledByAgentWake ? "Keeping Mac awake with Lid-Closed Awake on" : "Keeping Mac awake"
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
        return count == 1 ? "Also keep 1 detected session awake" : "Also keep \(count) detected sessions awake"
    }

    private static func protectDetectedSessionsDetail(count: Int) -> String {
        return "Keeps detected sessions awake until they exit."
    }

    private static func closedLidStatusTitle(_ status: ClosedLidStatus?) -> String {
        guard let status else {
            return ClosedLidModeAvailability.unavailableTitle
        }

        switch status {
        case .off:
            return "Lid-Closed Awake: Off"
        case .enabledByAgentWake:
            return "Lid-Closed Awake: On"
        case .ownershipPending:
            return "Lid-Closed Awake: Finishing Setup"
        case .enabledByOther:
            return "Lid-closed sleep is disabled by another tool"
        case .unknown:
            return "Lid-Closed Awake: Unknown"
        }
    }

    private static func closedLidStatusDetail(_ status: ClosedLidStatus?) -> String? {
        switch status {
        case .enabledByOther:
            return "AgentWake left it alone so it can be restored cleanly when you turn that tool off."
        case .unknown(let reason):
            return reason
        case .off, .enabledByAgentWake, .ownershipPending, .none:
            return nil
        }
    }

    private static func statusIncludesSessionSummary(currentState: AgentWakeState, sessionSummary: String?) -> Bool {
        currentState == .active && sessionSummary?.contains("kept awake") == true
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
