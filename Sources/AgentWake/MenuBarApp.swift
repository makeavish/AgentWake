import AppKit
import AgentWakeCore

@MainActor
final class MenuBarApp: NSObject {
    private let services: AgentWakeServices
    private let statusItem: NSStatusItem
    private let settingsWindowController: SettingsWindowController
    private var currentState: AgentWakeState
    private var refreshTimer: Timer?
    private var closedLidModeStatusLine = "Closed-Lid Mode status unknown"
    private var closedLidModeStatusDetail = "Use Refresh Status to check Closed-Lid Mode."
    private var closedLidModeActionInFlight = false

    init(
        services: AgentWakeServices,
        statusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength),
        settingsWindowController: SettingsWindowController? = nil,
        initialState: AgentWakeState = .idle
    ) {
        self.services = services
        self.statusItem = statusItem
        self.settingsWindowController = settingsWindowController ?? SettingsWindowController(services: services)
        self.currentState = initialState
        super.init()
        self.statusItem.length = NSStatusItem.squareLength
    }

    func start() {
        services.startAll()
        refreshState()
        refreshClosedLidModeStatusAsync()
        DispatchQueue.main.async { [weak self] in
            self?.presentOnboardingIfNeeded()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState()
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        services.stopAll()
    }

    private func refreshState() {
        let nextState = derivedState()
        let shouldRender = nextState != currentState || statusItem.menu == nil
        currentState = nextState

        if shouldRender {
            services.logStore.append(
                kind: .stateChanged,
                message: "State changed to \(currentState.menuTitle)",
                metadata: ["state": currentState.rawValue]
            )
        }

        renderMenu()
    }

    private func derivedState() -> AgentWakeState {
        AgentWakeState.derived(from: services.agentMonitor.aggregateHoldState)
    }

    private func renderMenu() {
        let snapshot = MenuBarModel.snapshot(
            currentState: currentState,
            sessionSummary: services.agentMonitor.sessionSummaryMessage(),
            closedLidModeStatus: closedLidModeStatusLine,
            closedLidModeDetail: closedLidModeStatusDetail,
            protectableDetectedSessionCount: services.agentMonitor.protectableDetectedSessionCount,
            enableClosedLidModeEnabled: canEnableClosedLidMode,
            disableClosedLidModeEnabled: canDisableClosedLidMode,
            integrationStatuses: services.integrationManager.snapshots()
        )

        if let button = statusItem.button {
            button.title = snapshot.statusItemAccessibilityTitle
            button.image = statusItemImage(for: snapshot.statusItemIcon)
            button.imagePosition = .imageOnly
            button.contentTintColor = statusItemTintColor(snapshot.statusItemIcon.tint)
            button.setAccessibilityTitle(snapshot.statusItemAccessibilityTitle)
            button.setAccessibilityLabel("AgentWake status: \(snapshot.statusItemIcon.accessibilityDescription)")
        }

        statusItem.menu = makeMenu(from: snapshot)
    }

    private func statusItemImage(for icon: MenuBarStatusIcon) -> NSImage? {
        let baseConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        guard let base = NSImage(
            systemSymbolName: icon.baseSystemImageName,
            accessibilityDescription: icon.accessibilityDescription
        )?.withSymbolConfiguration(baseConfiguration) else {
            return nil
        }

        guard let overlayName = icon.overlaySystemImageName,
              let overlay = NSImage(systemSymbolName: overlayName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)) else {
            base.isTemplate = true
            return base
        }

        let image = NSImage(size: NSSize(width: 22, height: 18))
        image.lockFocus()
        base.draw(in: NSRect(x: 1, y: 1, width: 16, height: 16))
        overlay.draw(in: NSRect(x: 13, y: 0, width: 8, height: 8))
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func statusItemTintColor(_ tint: MenuBarStatusTint) -> NSColor? {
        switch tint {
        case .secondary:
            return .secondaryLabelColor
        case .accent:
            return .controlAccentColor
        case .warning:
            return .systemOrange
        case .unknown:
            return .tertiaryLabelColor
        }
    }

    private var canEnableClosedLidMode: Bool {
        !closedLidModeActionInFlight &&
            closedLidModeStatusLine != "Closed-Lid Mode enabled" &&
            !closedLidModeStatusLine.contains("outside AgentWake") &&
            !closedLidModeStatusLine.contains("pending")
    }

    private var canDisableClosedLidMode: Bool {
        !closedLidModeActionInFlight && closedLidModeStatusLine == "Closed-Lid Mode enabled"
    }

    private func makeMenu(from snapshot: MenuBarSnapshot) -> NSMenu {
        let menu = NSMenu(title: "AgentWake")

        for item in snapshot.items {
            switch item.kind {
            case .status:
                menu.addItem(disabledMenuItem(for: item))
            case .diagnostic, .integrationStatus:
                menu.addItem(disabledMenuItem(for: item))
            case .separator:
                menu.addItem(.separator())
            case .protectDetectedSessions:
                menu.addItem(actionMenuItem(for: item, action: #selector(protectDetectedSessions)))
            case .releaseProtection:
                menu.addItem(actionMenuItem(for: item, action: #selector(releaseProtection)))
            case .closedLidEnable:
                menu.addItem(actionMenuItem(for: item, action: #selector(enableClosedLidMode)))
            case .closedLidDisable:
                menu.addItem(actionMenuItem(for: item, action: #selector(disableClosedLidMode)))
            case .refreshStatus:
                menu.addItem(actionMenuItem(for: item, action: #selector(refreshStatusNow)))
            case .repairIntegrations:
                menu.addItem(actionMenuItem(for: item, action: #selector(repairIntegrations)))
            case .settings:
                menu.addItem(actionMenuItem(for: item, action: #selector(openSettings)))
            case .quit:
                menu.addItem(actionMenuItem(for: item, action: #selector(quit)))
            }
        }

        return menu
    }

    private func disabledMenuItem(for item: MenuBarItem) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        menuItem.toolTip = item.detail
        return menuItem
    }

    private func actionMenuItem(for item: MenuBarItem, action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.isEnabled = item.isEnabled
        return menuItem
    }

    private func firstLine(of value: String) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? value
    }

    @objc private func openSettings() {
        settingsWindowController.refresh()
        NSApp.setActivationPolicy(.regular)
        settingsWindowController.showWindow(nil)
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshStatusNow() {
        services.agentMonitor.poll()
        services.assertionManager.reconcile()
        refreshClosedLidModeStatusAsync()
        refreshState()
        settingsWindowController.refresh()
    }

    @objc private func repairIntegrations() {
        let failures = repairAgentIntegrations()
        refreshStatusNow()
        presentRepairFailuresIfNeeded(failures)
    }

    @objc private func protectDetectedSessions() {
        _ = services.agentMonitor.protectDetectedSessions(at: Date())
        services.assertionManager.reconcile()
        refreshState()
        settingsWindowController.refresh()
    }

    @objc private func releaseProtection() {
        services.agentMonitor.releaseHeldSessions(at: Date())
        services.assertionManager.reconcile()
        refreshState()
        settingsWindowController.refresh()
    }

    @objc private func enableClosedLidMode() {
        guard !closedLidModeActionInFlight else {
            return
        }
        let controller = services.closedLidModeController
        guard confirmClosedLidEnable(currentValue: currentDisablesleepText(controller)) else {
            return
        }
        runClosedLidAction {
            try controller.enable()
        }
    }

    @objc private func disableClosedLidMode() {
        guard !closedLidModeActionInFlight else {
            return
        }
        let controller = services.closedLidModeController
        runClosedLidAction {
            try controller.disable()
        }
    }

    private func runClosedLidAction(action: @escaping @Sendable () throws -> String) {
        closedLidModeActionInFlight = true
        closedLidModeStatusDetail = "Closed-Lid Mode change is waiting for macOS administrator approval."
        refreshState()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try action() }
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                switch result {
                case .success(let message):
                    self.closedLidModeStatusLine = self.firstLine(of: message)
                    self.closedLidModeStatusDetail = message
                    self.closedLidModeActionInFlight = false
                    self.refreshState()
                case .failure(let error):
                    self.closedLidModeStatusLine = "Closed-Lid Mode status unknown"
                    self.closedLidModeStatusDetail = error.localizedDescription
                    self.closedLidModeActionInFlight = false
                    self.refreshClosedLidModeStatusAsync()
                    self.refreshState()
                    self.presentMessage(title: "Closed-Lid Mode failed", message: error.localizedDescription, style: .warning)
                }
            }
        }
    }

    private func currentDisablesleepText(_ controller: ClosedLidModeController) -> String {
        do {
            return String(try controller.currentDisablesleepValue())
        } catch {
            return "unknown"
        }
    }

    private func confirmClosedLidEnable(currentValue: String) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Turn On Lid-Closed Awake?"
        alert.informativeText = """
        AgentWake will request administrator permission to disable lid sleep via pmset disablesleep. This setting affects all apps system-wide.

        When you turn Lid-Closed Awake off, AgentWake will restore your previous value (currently: \(currentValue)).
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        NSApp.setActivationPolicy(.accessory)
        return response == .alertFirstButtonReturn
    }

    private func refreshClosedLidModeStatusAsync() {
        guard !closedLidModeActionInFlight else {
            return
        }

        let controller = services.closedLidModeController
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let message = controller.statusMessage()
            DispatchQueue.main.async {
                guard let self, !self.closedLidModeActionInFlight else {
                    return
                }

                self.closedLidModeStatusLine = self.firstLine(of: message)
                self.closedLidModeStatusDetail = message
                self.refreshState()
            }
        }
    }

    private func repairAgentIntegrations() -> [String] {
        var failures: [String] = []
        for agentID in ["claude-code", "codex-cli"] {
            do {
                _ = try services.integrationManager.enableAutoInstall(agentID: agentID)
            } catch {
                failures.append("\(agentID): \(error.localizedDescription)")
            }
        }
        return failures
    }

    private func presentRepairFailuresIfNeeded(_ failures: [String]) {
        guard !failures.isEmpty else {
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Integration repair failed"
        alert.informativeText = failures.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.setActivationPolicy(.accessory)
    }

    private func presentOnboardingIfNeeded() {
        guard ProcessInfo.processInfo.environment["AGENTWAKE_SKIP_ONBOARDING"] != "1" else {
            return
        }

        var settings = services.settingsStore.settings
        guard !settings.hasCompletedOnboarding else {
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Welcome to AgentWake"
        alert.informativeText = onboardingMessage()
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Done")
        let response = alert.runModal()

        settings.hasCompletedOnboarding = true
        try? services.settingsStore.save(settings)

        if response == .alertFirstButtonReturn {
            openSettings()
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func onboardingMessage() -> String {
        let hookSummary = services.integrationManager.installPreviews().map { preview in
            var lines = [
                "\(preview.displayName): \(preview.settingsFile.isEmpty ? "config path unavailable" : preview.settingsFile)"
            ]
            if !preview.dryRunDiff.isEmpty {
                lines += preview.dryRunDiff.map { "  - \($0)" }
            }
            if let failureReason = preview.failureReason {
                lines.append("  - \(failureReason)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")

        return """
        1. AgentWake adds local hooks so Claude Code and Codex can report session activity.
        \(hookSummary)

        2. Lid-Closed Awake on battery requires administrator approval. Set it up now or later from Settings.

        3. Open Claude Code or Codex. AgentWake will catch the next session automatically.
        """
    }

    private func presentMessage(title: String, message: String, style: NSAlert.Style) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
