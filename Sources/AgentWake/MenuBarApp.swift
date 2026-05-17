import AppKit
import AgentWakeCore

@MainActor
final class MenuBarApp: NSObject {
    private let services: AgentWakeServices
    private let statusItem: NSStatusItem
    private let settingsWindowController: SettingsWindowController
    private var currentState: AgentWakeState
    private var refreshTimer: Timer?
    private var closedLidStatus = ClosedLidStatus.unknown(reason: "Use Refresh Status to check Lid-Closed Awake.")
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
            closedLidStatus: closedLidStatus,
            closedLidModeDetail: closedLidModeStatusDetail,
            protectableDetectedSessionCount: services.agentMonitor.protectableDetectedSessionCount,
            enableClosedLidModeEnabled: canEnableClosedLidMode,
            disableClosedLidModeEnabled: canDisableClosedLidMode,
            takeClosedLidOwnershipEnabled: canTakeClosedLidOwnership,
            isSleepProtectionPaused: isSleepProtectionPaused,
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
        case .warning:
            return .systemOrange
        case .secondary, .accent, .unknown:
            // Let NSStatusBarButton render template images against the actual
            // menu bar appearance. App-label colors can be nearly invisible
            // when the menu bar and app appearances differ.
            return nil
        }
    }

    private var canEnableClosedLidMode: Bool {
        !closedLidModeActionInFlight &&
            (closedLidStatus == .off || isUnknownClosedLidStatus)
    }

    private var canDisableClosedLidMode: Bool {
        !closedLidModeActionInFlight && closedLidStatus == .enabledByAgentWake
    }

    private var canTakeClosedLidOwnership: Bool {
        !closedLidModeActionInFlight && closedLidStatus == .enabledByOther
    }

    private var isUnknownClosedLidStatus: Bool {
        if case .unknown = closedLidStatus {
            return true
        }
        return false
    }

    private var isSleepProtectionPaused: Bool {
        services.agentMonitor.aggregateHoldState.isPaused
    }

    private func makeMenu(from snapshot: MenuBarSnapshot) -> NSMenu {
        let menu = NSMenu(title: "AgentWake")
        menu.autoenablesItems = false

        for item in snapshot.items {
            switch item.kind {
            case .status:
                menu.addItem(disabledMenuItem(for: item))
            case .diagnostic, .integrationStatus:
                menu.addItem(disabledMenuItem(for: item))
            case .separator:
                menu.addItem(.separator())
            case .pauseProtection:
                menu.addItem(pauseProtectionMenuItem(for: item))
            case .resumeProtection:
                menu.addItem(actionMenuItem(for: item, action: #selector(resumeSleepProtection)))
            case .protectDetectedSessions:
                menu.addItem(actionMenuItem(for: item, action: #selector(protectDetectedSessions)))
            case .closedLidEnable:
                menu.addItem(actionMenuItem(for: item, action: #selector(enableClosedLidMode)))
            case .closedLidDisable:
                menu.addItem(actionMenuItem(for: item, action: #selector(disableClosedLidMode)))
            case .closedLidTakeOwnership:
                menu.addItem(actionMenuItem(for: item, action: #selector(takeClosedLidOwnership)))
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

    private func pauseProtectionMenuItem(for item: MenuBarItem) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = item.isEnabled
        let submenu = NSMenu(title: item.title)
        submenu.autoenablesItems = false
        addPauseOption("Pause for 30 minutes", tag: 30 * 60, to: submenu)
        addPauseOption("Pause for 1 hour", tag: 60 * 60, to: submenu)
        addPauseOption("Pause for 4 hours", tag: 4 * 60 * 60, to: submenu)
        addPauseOption("Pause until tomorrow morning", tag: -1, to: submenu)
        addPauseOption("Pause indefinitely", tag: 0, to: submenu)
        menuItem.submenu = submenu
        return menuItem
    }

    private func addPauseOption(_ title: String, tag: Int, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(pauseSleepProtectionOption(_:)), keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.isEnabled = true
        menu.addItem(item)
    }

    @objc private func pauseSleepProtectionOption(_ sender: NSMenuItem) {
        pauseSleepProtection(until: pauseExpiration(forTag: sender.tag, from: Date()))
    }

    private func pauseSleepProtection(until expiresAt: Date?) {
        do {
            try services.settingsStore.pauseSleepProtection(until: expiresAt)
            services.agentMonitor.poll()
            services.assertionManager.reconcile()
            refreshState()
            settingsWindowController.refresh()
        } catch {
            presentMessage(title: "Could not pause sleep protection", message: error.localizedDescription, style: .warning)
        }
    }

    private func pauseExpiration(forTag tag: Int, from now: Date) -> Date? {
        if tag > 0 {
            return now.addingTimeInterval(TimeInterval(tag))
        }
        if tag == -1 {
            return Calendar.current.nextDate(
                after: now,
                matching: DateComponents(hour: 8, minute: 0, second: 0),
                matchingPolicy: .nextTime
            )
        }
        return nil
    }

    @objc private func resumeSleepProtection() {
        do {
            try services.settingsStore.resumeSleepProtection()
            services.agentMonitor.poll()
            services.assertionManager.reconcile()
            refreshState()
            settingsWindowController.refresh()
        } catch {
            presentMessage(title: "Could not resume sleep protection", message: error.localizedDescription, style: .warning)
        }
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

    @objc private func takeClosedLidOwnership() {
        guard !closedLidModeActionInFlight else {
            return
        }
        guard confirmClosedLidOwnershipTakeover() else {
            return
        }
        let controller = services.closedLidModeController
        runClosedLidAction {
            try controller.takeOwnership()
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
                    self.closedLidStatus = self.services.closedLidModeController.status()
                    self.closedLidModeStatusDetail = message
                    self.closedLidModeActionInFlight = false
                    self.refreshState()
                case .failure(let error):
                    self.closedLidStatus = .unknown(reason: error.localizedDescription)
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

    private func confirmClosedLidOwnershipTakeover() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Let AgentWake manage this setting?"
        alert.informativeText = """
        Lid-closed sleep is already disabled by another tool or a previous pmset command.

        AgentWake will record this as AgentWake-owned and restore disablesleep=0 when you turn Lid-Closed Awake off.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Take Ownership")
        alert.addButton(withTitle: "Cancel")
        let response = runFrontmostAlert(alert)
        NSApp.setActivationPolicy(.accessory)
        return response == .alertFirstButtonReturn
    }

    private func confirmClosedLidEnable(currentValue: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Turn On Lid-Closed Awake?"
        alert.informativeText = closedLidEnableConfirmationText(currentValue: currentValue)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let response = runFrontmostAlert(alert)
        NSApp.setActivationPolicy(.accessory)
        return response == .alertFirstButtonReturn
    }

    private func closedLidEnableConfirmationText(currentValue: String) -> String {
        var message = """
        AgentWake will request administrator permission to disable lid sleep via pmset disablesleep. This setting affects all apps system-wide.

        When you turn Lid-Closed Awake off, AgentWake will restore your previous value (currently: \(currentValue)).
        """

        if PowerSourceReader.current() == .battery {
            message += "\n\nBattery & thermal cutoffs are not yet enforced. For long overnight runs on battery, plug into AC."
        }

        return message
    }

    private func refreshClosedLidModeStatusAsync() {
        guard !closedLidModeActionInFlight else {
            return
        }

        let controller = services.closedLidModeController
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = controller.status()
            let message = controller.statusMessage()
            DispatchQueue.main.async {
                guard let self, !self.closedLidModeActionInFlight else {
                    return
                }

                self.closedLidStatus = status
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

        let alert = NSAlert()
        alert.messageText = "Integration repair failed"
        alert.informativeText = failures.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        runFrontmostAlert(alert)
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

        let onboarding = OnboardingWindowController(previews: services.integrationManager.installPreviews())
        let response = onboarding.runFrontmostModal()

        settings.hasCompletedOnboarding = true
        try? services.settingsStore.save(settings)

        if response == .openSettings {
            openSettings()
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func presentMessage(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        runFrontmostAlert(alert)
        NSApp.setActivationPolicy(.accessory)
    }

    @discardableResult
    private func runFrontmostAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let window = alert.window
        window.level = .modalPanel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        return alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
