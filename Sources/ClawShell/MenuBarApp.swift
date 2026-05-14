import AppKit
import ClawShellCore

@MainActor
final class MenuBarApp: NSObject {
    private let services: ClawShellServices
    private let statusItem: NSStatusItem
    private let settingsWindowController: SettingsWindowController
    private var currentState: ClawShellState

    init(
        services: ClawShellServices,
        statusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength),
        settingsWindowController: SettingsWindowController = SettingsWindowController(),
        initialState: ClawShellState = .idle
    ) {
        self.services = services
        self.statusItem = statusItem
        self.settingsWindowController = settingsWindowController
        self.currentState = initialState
        super.init()
    }

    func start() {
        services.startAll()
        services.logStore.append(
            kind: .stateChanged,
            message: "State changed to \(currentState.menuTitle)",
            metadata: ["state": currentState.rawValue]
        )
        renderMenu()
    }

    func stop() {
        services.stopAll()
    }

    private func renderMenu() {
        let snapshot = MenuBarModel.snapshot(currentState: currentState)

        if let button = statusItem.button {
            button.title = snapshot.statusItemTitle
            button.setAccessibilityLabel("ClawShell status: \(snapshot.currentState.menuTitle)")
        }

        statusItem.menu = makeMenu(from: snapshot)
    }

    private func makeMenu(from snapshot: MenuBarSnapshot) -> NSMenu {
        let menu = NSMenu(title: "ClawShell")

        for item in snapshot.items {
            switch item.kind {
            case .status:
                menu.addItem(disabledMenuItem(for: item))
                menu.addItem(.separator())
            case .placeholderState:
                menu.addItem(disabledMenuItem(for: item))
            case .settings:
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
        NSApp.setActivationPolicy(.regular)
        settingsWindowController.showWindow(nil)
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
