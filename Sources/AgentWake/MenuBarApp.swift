import AppKit
import AgentWakeCore

@MainActor
final class MenuBarApp: NSObject {
    private static let pauseTomorrowMorningTag = -1
    private static let pauseIndefinitelyTag = -2
    private static let keepMacActiveIndefinitelyTag = -2

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
        let holdState = services.agentMonitor.aggregateHoldState
        let snapshot = MenuBarModel.snapshot(
            currentState: currentState,
            sessionSummary: services.agentMonitor.sessionSummaryMessage(),
            closedLidStatus: closedLidStatus,
            closedLidModeDetail: closedLidModeMenuDetail(for: holdState),
            protectableDetectedSessionCount: services.agentMonitor.protectableDetectedSessionCount,
            enableClosedLidModeEnabled: canEnableClosedLidMode,
            disableClosedLidModeEnabled: canDisableClosedLidMode,
            takeClosedLidOwnershipEnabled: canTakeClosedLidOwnership,
            isSleepProtectionPaused: isSleepProtectionPaused,
            isManualKeepMacActive: holdState.isManuallyKeepingAwake,
            manualKeepMacActiveDetail: manualKeepMacActiveDetail(for: holdState),
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
            (closedLidStatus == .off || isUnknownClosedLidStatus) &&
            services.agentMonitor.aggregateHoldState.shouldHold
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
            case .keepMacActive:
                menu.addItem(keepMacActiveMenuItem(for: item))
            case .stopKeepingMacActive:
                menu.addItem(actionMenuItem(for: item, action: #selector(stopKeepingMacActive)))
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
        addPauseOption("Pause until tomorrow morning", tag: Self.pauseTomorrowMorningTag, to: submenu)
        addPauseOption("Pause indefinitely", tag: Self.pauseIndefinitelyTag, to: submenu)
        menuItem.submenu = submenu
        return menuItem
    }

    private func keepMacActiveMenuItem(for item: MenuBarItem) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = item.isEnabled
        let submenu = NSMenu(title: item.title)
        submenu.autoenablesItems = false
        addKeepMacActiveOption("For 30 minutes", tag: 30 * 60, to: submenu)
        addKeepMacActiveOption("For 1 hour", tag: 60 * 60, to: submenu)
        addKeepMacActiveOption("For 4 hours", tag: 4 * 60 * 60, to: submenu)
        addKeepMacActiveOption("Indefinitely", tag: Self.keepMacActiveIndefinitelyTag, to: submenu)
        menuItem.submenu = submenu
        return menuItem
    }

    private func addKeepMacActiveOption(_ title: String, tag: Int, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(keepMacActiveOption(_:)), keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.isEnabled = true
        menu.addItem(item)
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

    @objc private func keepMacActiveOption(_ sender: NSMenuItem) {
        keepMacActive(until: keepMacActiveExpiration(forTag: sender.tag, from: Date()))
    }

    private func keepMacActive(until expiresAt: Date?) {
        do {
            try services.settingsStore.keepMacAwake(until: expiresAt)
            services.agentMonitor.poll()
            services.assertionManager.reconcile()
            refreshState()
            settingsWindowController.refresh()
        } catch {
            presentMessage(title: "Could not keep Mac active", message: error.localizedDescription, style: .warning)
        }
    }

    @objc private func stopKeepingMacActive() {
        do {
            try services.settingsStore.stopKeepingMacAwake()
            services.agentMonitor.poll()
            services.assertionManager.reconcile()
            refreshState()
            settingsWindowController.refresh()
        } catch {
            presentMessage(title: "Could not stop keeping Mac active", message: error.localizedDescription, style: .warning)
        }
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
        if tag == Self.pauseTomorrowMorningTag {
            return Calendar.current.nextDate(
                after: now,
                matching: DateComponents(hour: 8, minute: 0, second: 0),
                matchingPolicy: .nextTime
            )
        }
        if tag == Self.pauseIndefinitelyTag {
            return nil
        }
        return nil
    }

    private func keepMacActiveExpiration(forTag tag: Int, from now: Date) -> Date? {
        if tag > 0 {
            return now.addingTimeInterval(TimeInterval(tag))
        }
        if tag == Self.keepMacActiveIndefinitelyTag {
            return nil
        }
        return nil
    }

    private func manualKeepMacActiveDetail(for holdState: AgentAggregateHoldState) -> String? {
        guard holdState.isManuallyKeepingAwake else {
            return nil
        }

        guard let expiresAt = holdState.manualKeepAwakeExpiresAt else {
            return "Manual Mac-active hold is on indefinitely."
        }

        return "Manual Mac-active hold ends in \(relativeDuration(until: expiresAt, from: Date()))."
    }

    private func closedLidModeMenuDetail(for holdState: AgentAggregateHoldState) -> String {
        if (closedLidStatus == .off || isUnknownClosedLidStatus), !holdState.shouldHold {
            return "Start or protect a session, or use Keep Mac Active first."
        }

        return closedLidModeStatusDetail
    }

    private func relativeDuration(until date: Date, from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds < 60 {
            return "\(seconds) seconds"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }

        let hours = minutes / 60
        if hours < 24 {
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }

        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
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
        let services = self.services
        runClosedLidAction {
            try services.enableClosedLidMode()
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
        closedLidModeStatusDetail = "Closed-Lid Mode change is waiting for helper approval."
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
        AgentWake will use its installed helper to disable lid sleep now, then restore normal sleep when current protection ends. If the helper still needs approval, macOS will ask once in System Settings.

        Current value: \(currentValue)
        """

        if PowerSourceReader.current() == .battery {
            message += "\n\n\(ClosedLidUserFacingCopy.safetyNotice(settings: services.settingsStore.settings.safety))"
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
