import AppKit
import AgentWakeCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsViewController: SettingsViewController

    init(services: AgentWakeServices) {
        let contentViewController = SettingsViewController(services: services)
        self.settingsViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        window.title = "AgentWake Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 360))
        window.center()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
    }

    override func close() {
        super.close()
        NSApp.setActivationPolicy(.accessory)
    }

    func refresh() {
        settingsViewController.refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
private final class SettingsViewController: NSViewController {
    private let services: AgentWakeServices
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let claudeStatusLabel = NSTextField(labelWithString: "")
    private let codexStatusLabel = NSTextField(labelWithString: "")
    private let repairButton = NSButton(title: "Repair Integrations", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)

    init(services: AgentWakeServices) {
        self.services = services
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let rootView = NSView()
        rootView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "AgentWake Settings")
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.setAccessibilityLabel("AgentWake Settings")

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("AgentWake runtime status")

        let normalProtectionLabel = keyValueLabel(key: "Normal sleep protection", value: "On")
        let bagModeLabel = keyValueLabel(key: "Closed-Lid Mode", value: "Unavailable")

        let claudeTitle = keyValueLabel(key: "Claude Code", value: "")
        let codexTitle = keyValueLabel(key: "Codex CLI", value: "")
        claudeStatusLabel.textColor = .secondaryLabelColor
        codexStatusLabel.textColor = .secondaryLabelColor

        let integrationGrid = NSGridView(views: [
            [claudeTitle, claudeStatusLabel],
            [codexTitle, codexStatusLabel]
        ])
        integrationGrid.column(at: 0).xPlacement = .leading
        integrationGrid.column(at: 1).xPlacement = .leading
        integrationGrid.rowSpacing = 8
        integrationGrid.columnSpacing = 18

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.setAccessibilityLabel("Close settings")

        repairButton.target = self
        repairButton.action = #selector(repairIntegrations)
        repairButton.bezelStyle = .rounded
        repairButton.setAccessibilityLabel("Repair integrations")

        refreshButton.target = self
        refreshButton.action = #selector(refreshAction)
        refreshButton.bezelStyle = .rounded
        refreshButton.setAccessibilityLabel("Refresh status")

        let buttonStack = NSStackView(views: [repairButton, refreshButton, closeButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .trailing
        buttonStack.spacing = 8

        let stack = NSStackView(views: [
            titleLabel,
            statusLabel,
            normalProtectionLabel,
            bagModeLabel,
            separator(),
            integrationGrid,
            buttonStack
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: rootView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor)
        ])

        view = rootView
        refresh()
    }

    func refresh() {
        guard isViewLoaded else {
            return
        }

        statusLabel.stringValue = services.agentMonitor.sessionSummaryMessage()
        let snapshots = Dictionary(
            uniqueKeysWithValues: services.integrationManager.snapshots().map { ($0.agentID, $0) }
        )
        claudeStatusLabel.stringValue = statusText(for: snapshots["claude-code"])
        codexStatusLabel.stringValue = statusText(for: snapshots["codex-cli"])
    }

    private func keyValueLabel(key: String, value: String) -> NSTextField {
        let text = value.isEmpty ? key : "\(key): \(value)"
        let label = NSTextField(labelWithString: text)
        label.font = .preferredFont(forTextStyle: .body)
        return label
    }

    private func statusText(for snapshot: IntegrationStatusSnapshot?) -> String {
        guard let snapshot else {
            return "Not installed"
        }

        var parts = [snapshot.status.displayTitle]
        if snapshot.autoInstallSuppressed {
            parts.append("auto-install off")
        }
        if let reason = snapshot.failureReason, !reason.isEmpty {
            parts.append(reason)
        }
        return parts.joined(separator: " - ")
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @objc private func repairIntegrations() {
        var failures: [String] = []
        for agentID in ["claude-code", "codex-cli"] {
            do {
                _ = try services.integrationManager.enableAutoInstall(agentID: agentID)
            } catch {
                failures.append("\(agentID): \(error.localizedDescription)")
            }
        }

        services.agentMonitor.poll()
        services.assertionManager.reconcile()
        refresh()

        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Integration repair failed"
            alert.informativeText = failures.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window) { _ in }
            } else {
                alert.runModal()
            }
        }
    }

    @objc private func refreshAction() {
        services.agentMonitor.poll()
        services.assertionManager.reconcile()
        refresh()
    }

    @objc private func closeWindow() {
        view.window?.close()
        NSApp.setActivationPolicy(.accessory)
    }
}
