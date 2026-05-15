import AppKit
import AgentWakeCore

@MainActor
final class MenuBarApp: NSObject {
    private let services: AgentWakeServices
    private let statusItem: NSStatusItem
    private let settingsWindowController: SettingsWindowController
    private var currentState: AgentWakeState
    private var refreshTimer: Timer?

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
    }

    func start() {
        services.startAll()
        refreshState()
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
            integrationStatuses: services.integrationManager.snapshots()
        )

        if let button = statusItem.button {
            button.title = snapshot.statusItemTitle
            button.setAccessibilityLabel("AgentWake status: \(snapshot.currentState.menuTitle)")
        }

        statusItem.menu = makeMenu(from: snapshot)
    }

    private func makeMenu(from snapshot: MenuBarSnapshot) -> NSMenu {
        let menu = NSMenu(title: "AgentWake")

        for item in snapshot.items {
            switch item.kind {
            case .status:
                menu.addItem(disabledMenuItem(for: item))
                menu.addItem(.separator())
            case .diagnostic, .integrationStatus:
                menu.addItem(disabledMenuItem(for: item))
            case .refreshStatus:
                menu.addItem(actionMenuItem(for: item, action: #selector(refreshStatusNow)))
            case .repairIntegrations:
                menu.addItem(actionMenuItem(for: item, action: #selector(repairIntegrations)))
            case .settings:
                menu.addItem(.separator())
                menu.addItem(actionMenuItem(for: item, action: #selector(openSettings)))
                menu.addItem(.separator())
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
        refreshState()
        settingsWindowController.refresh()
    }

    @objc private func repairIntegrations() {
        let failures = repairAgentIntegrations()
        refreshStatusNow()
        presentRepairFailuresIfNeeded(failures)
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
