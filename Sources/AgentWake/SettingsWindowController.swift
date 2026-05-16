import AppKit
import AgentWakeCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsViewController: SettingsViewController

    init(services: AgentWakeServices) {
        let contentViewController = SettingsViewController(services: services)
        self.settingsViewController = contentViewController
        let window = SettingsWindow(contentViewController: contentViewController)
        window.title = "AgentWake Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 700, height: 640))
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

private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
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
    private let sessionListLabel = NSTextField(wrappingLabelWithString: "")
    private let closedLidModeStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let claudeStatusLabel = NSTextField(labelWithString: "")
    private let codexStatusLabel = NSTextField(labelWithString: "")
    private let claudeDetailsButton = NSButton(title: "Show details", target: nil, action: nil)
    private let codexDetailsButton = NSButton(title: "Show details", target: nil, action: nil)
    private let claudeDetailsLabel = NSTextField(wrappingLabelWithString: "")
    private let codexDetailsLabel = NSTextField(wrappingLabelWithString: "")
    private let claudeRemoveButton = NSButton(title: "Remove", target: nil, action: nil)
    private let codexRemoveButton = NSButton(title: "Remove", target: nil, action: nil)
    private let protectButton = NSButton(title: "Keep sessions awake", target: nil, action: nil)
    private let enableClosedLidButton = NSButton(title: "Turn On", target: nil, action: nil)
    private let disableClosedLidButton = NSButton(title: "Turn Off", target: nil, action: nil)
    private let repairButton = NSButton(title: "Reinstall agent hooks", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private var closedLidActionInFlight = false
    private var refreshTimer: Timer?

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

        let titleLabel = NSTextField(labelWithString: "AgentWake")
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.setAccessibilityLabel("AgentWake Settings")

        statusLabel.font = .preferredFont(forTextStyle: .title3)
        statusLabel.setAccessibilityLabel("AgentWake runtime status")
        sessionListLabel.textColor = .secondaryLabelColor
        sessionListLabel.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        sessionListLabel.maximumNumberOfLines = 4
        sessionListLabel.setAccessibilityLabel("Detected agent sessions")

        closedLidModeStatusLabel.textColor = .secondaryLabelColor
        closedLidModeStatusLabel.setAccessibilityLabel("Closed-Lid Mode status")

        let claudeTitle = keyValueLabel(key: "Claude Code", value: "")
        let codexTitle = keyValueLabel(key: "Codex CLI", value: "")
        claudeStatusLabel.textColor = .secondaryLabelColor
        codexStatusLabel.textColor = .secondaryLabelColor
        claudeDetailsLabel.textColor = .secondaryLabelColor
        codexDetailsLabel.textColor = .secondaryLabelColor
        claudeDetailsLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        codexDetailsLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        claudeDetailsLabel.isHidden = true
        codexDetailsLabel.isHidden = true

        claudeDetailsButton.target = self
        claudeDetailsButton.action = #selector(toggleClaudeDetails)
        claudeDetailsButton.bezelStyle = .disclosure
        claudeDetailsButton.setAccessibilityLabel("Show Claude Code integration details")

        codexDetailsButton.target = self
        codexDetailsButton.action = #selector(toggleCodexDetails)
        codexDetailsButton.bezelStyle = .disclosure
        codexDetailsButton.setAccessibilityLabel("Show Codex CLI integration details")

        claudeRemoveButton.target = self
        claudeRemoveButton.action = #selector(removeClaudeIntegration)
        claudeRemoveButton.bezelStyle = .rounded
        claudeRemoveButton.setAccessibilityLabel("Remove Claude Code agent hook")

        codexRemoveButton.target = self
        codexRemoveButton.action = #selector(removeCodexIntegration)
        codexRemoveButton.bezelStyle = .rounded
        codexRemoveButton.setAccessibilityLabel("Remove Codex CLI agent hook")

        let integrationStack = NSStackView(views: [
            integrationRow(title: claudeTitle, status: claudeStatusLabel, detailsButton: claudeDetailsButton, removeButton: claudeRemoveButton),
            claudeDetailsLabel,
            integrationRow(title: codexTitle, status: codexStatusLabel, detailsButton: codexDetailsButton, removeButton: codexRemoveButton),
            codexDetailsLabel
        ])
        integrationStack.orientation = .vertical
        integrationStack.alignment = .leading
        integrationStack.spacing = 6

        protectButton.target = self
        protectButton.action = #selector(protectDetectedSessions)
        protectButton.bezelStyle = .rounded
        protectButton.setAccessibilityLabel("Keep detected sessions awake")

        enableClosedLidButton.target = self
        enableClosedLidButton.action = #selector(enableClosedLidMode)
        enableClosedLidButton.bezelStyle = .rounded
        enableClosedLidButton.setAccessibilityLabel("Turn on lid-closed awake")

        disableClosedLidButton.target = self
        disableClosedLidButton.action = #selector(disableClosedLidMode)
        disableClosedLidButton.bezelStyle = .rounded
        disableClosedLidButton.setAccessibilityLabel("Turn off lid-closed awake")

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.setAccessibilityLabel("Close settings")

        repairButton.target = self
        repairButton.action = #selector(repairIntegrations)
        repairButton.bezelStyle = .rounded
        repairButton.setAccessibilityLabel("Reinstall agent hooks")

        refreshButton.target = self
        refreshButton.action = #selector(refreshAction)
        refreshButton.bezelStyle = .rounded
        refreshButton.setAccessibilityLabel("Refresh status")

        let sessionButtons = rowStack([protectButton, refreshButton])
        let closedLidButtons = rowStack([enableClosedLidButton, disableClosedLidButton])
        let footerButtons = rowStack([NSView(), closeButton])

        let stack = NSStackView(views: [
            titleLabel,
            sectionHeader("Sessions"),
            statusLabel,
            sessionListLabel,
            sessionButtons,
            separator(),
            sectionHeader("Lid-Closed Awake"),
            closedLidModeStatusLabel,
            closedLidButtons,
            separator(),
            sectionHeader("Integrations"),
            integrationStack,
            repairButton,
            footerButtons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: rootView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor),
            sessionButtons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            closedLidButtons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            integrationStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            footerButtons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48)
        ])

        view = rootView
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startRefreshingWhileVisible()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopRefreshingWhileVisible()
    }

    func refresh() {
        guard isViewLoaded else {
            return
        }

        let protectableCount = services.agentMonitor.protectableDetectedSessionCount
        statusLabel.stringValue = services.agentMonitor.sessionSummaryMessage()
        sessionListLabel.stringValue = services.agentMonitor.sessionOverviewMessage()
        protectButton.title = protectButtonTitle(count: protectableCount)
        protectButton.isEnabled = protectableCount > 0

        let closedLidStatusMessage = services.closedLidModeController.statusMessage()
        closedLidModeStatusLabel.stringValue = closedLidDisplayText(for: closedLidStatusMessage)
        enableClosedLidButton.isEnabled = !closedLidActionInFlight &&
            canEnableClosedLidMode(statusMessage: closedLidStatusMessage)
        disableClosedLidButton.isEnabled = !closedLidActionInFlight &&
            canDisableClosedLidMode(statusMessage: closedLidStatusMessage)

        let snapshots = Dictionary(
            uniqueKeysWithValues: services.integrationManager.snapshots().map { ($0.agentID, $0) }
        )
        let previews = Dictionary(
            uniqueKeysWithValues: services.integrationManager.installPreviews().map { ($0.agentID, $0) }
        )
        claudeStatusLabel.stringValue = statusText(for: snapshots["claude-code"])
        codexStatusLabel.stringValue = statusText(for: snapshots["codex-cli"])
        claudeDetailsLabel.stringValue = detailsText(for: snapshots["claude-code"], preview: previews["claude-code"])
        codexDetailsLabel.stringValue = detailsText(for: snapshots["codex-cli"], preview: previews["codex-cli"])
        claudeRemoveButton.isEnabled = snapshots["claude-code"]?.status == .installed
        codexRemoveButton.isEnabled = snapshots["codex-cli"]?.status == .installed
    }

    private func keyValueLabel(key: String, value: String) -> NSTextField {
        let text = value.isEmpty ? key : "\(key): \(value)"
        let label = NSTextField(labelWithString: text)
        label.font = .preferredFont(forTextStyle: .body)
        return label
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .preferredFont(forTextStyle: .headline)
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

    private func detailsText(for snapshot: IntegrationStatusSnapshot?, preview: IntegrationPreview?) -> String {
        let settingsFile = snapshot?.settingsFile ?? preview?.settingsFile ?? "No config path available"
        var lines = ["Config: \(settingsFile)"]

        if let preview, !preview.dryRunDiff.isEmpty {
            lines.append("Will change:")
            lines += preview.dryRunDiff.map { "- \($0)" }
        }

        if let failureReason = snapshot?.failureReason ?? preview?.failureReason, !failureReason.isEmpty {
            lines.append("Issue: \(failureReason)")
        }

        return lines.joined(separator: "\n")
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func rowStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func integrationRow(
        title: NSTextField,
        status: NSTextField,
        detailsButton: NSButton,
        removeButton: NSButton
    ) -> NSStackView {
        let spacer = NSView()
        let stack = rowStack([detailsButton, title, spacer, status, removeButton])
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        return stack
    }

    private func protectButtonTitle(count: Int) -> String {
        guard count > 0 else {
            return "Keep sessions awake"
        }

        return count == 1 ? "Keep 1 session awake" : "Keep \(count) sessions awake"
    }

    private func closedLidDisplayText(for message: String) -> String {
        let lines = message.split(separator: "\n").map(String.init)
        guard let first = lines.first else {
            return "Status unknown"
        }

        switch first {
        case "Closed-Lid Mode off":
            return "Off"
        case "Closed-Lid Mode enabled":
            return "Enabled\nAgentWake will restore the previous sleep setting when this is disabled."
        case "Closed-Lid Mode already enabled":
            return "Enabled"
        case "Closed-Lid Mode ownership pending":
            return "Finishing setup\nDisable is blocked until AgentWake confirms ownership."
        case "Closed-Lid Mode enabled outside AgentWake":
            return "On outside AgentWake\nDisable is blocked because AgentWake did not create this state."
        case "Closed-Lid Mode status unknown":
            return (["Status unknown"] + lines.dropFirst()).joined(separator: "\n")
        default:
            return first
        }
    }

    private func canEnableClosedLidMode(statusMessage: String) -> Bool {
        let firstLine = statusMessage.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine == "Closed-Lid Mode off" || firstLine == "Closed-Lid Mode already off"
    }

    private func canDisableClosedLidMode(statusMessage: String) -> Bool {
        let firstLine = statusMessage.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine == "Closed-Lid Mode enabled" || firstLine == "Closed-Lid Mode already enabled"
    }

    private func presentAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    @objc private func protectDetectedSessions() {
        _ = services.agentMonitor.protectDetectedSessions(at: Date())
        services.assertionManager.reconcile()
        refresh()
    }

    @objc private func toggleClaudeDetails() {
        claudeDetailsLabel.isHidden.toggle()
        claudeDetailsButton.state = claudeDetailsLabel.isHidden ? .off : .on
    }

    @objc private func toggleCodexDetails() {
        codexDetailsLabel.isHidden.toggle()
        codexDetailsButton.state = codexDetailsLabel.isHidden ? .off : .on
    }

    @objc private func removeClaudeIntegration() {
        removeIntegration(agentID: "claude-code", displayName: "Claude Code")
    }

    @objc private func removeCodexIntegration() {
        removeIntegration(agentID: "codex-cli", displayName: "Codex CLI")
    }

    private func removeIntegration(agentID: String, displayName: String) {
        let alert = NSAlert()
        alert.messageText = "Remove \(displayName) hook?"
        alert.informativeText = "AgentWake will remove only its owned hook from the agent config and stop reinstalling it automatically."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let runRemoval = { [weak self] in
            guard let self else {
                return
            }
            do {
                _ = try self.services.integrationManager.removeIntegration(agentID: agentID, at: Date())
                self.refresh()
            } catch {
                self.presentAlert(title: "Could not remove \(displayName) hook", message: error.localizedDescription, style: .warning)
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else {
                    return
                }
                runRemoval()
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            runRemoval()
        }
    }

    @objc private func enableClosedLidMode() {
        let controller = services.closedLidModeController
        confirmClosedLidEnable(currentValue: currentDisablesleepText(controller)) { [weak self] in
            self?.runClosedLidModeAction {
                try controller.enable()
            }
        }
    }

    @objc private func disableClosedLidMode() {
        let controller = services.closedLidModeController
        runClosedLidModeAction {
            try controller.disable()
        }
    }

    private func runClosedLidModeAction(action: @escaping @Sendable () throws -> String) {
        guard !closedLidActionInFlight else {
            return
        }

        closedLidActionInFlight = true
        closedLidModeStatusLabel.stringValue = "Waiting for macOS administrator approval"
        enableClosedLidButton.isEnabled = false
        disableClosedLidButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try action() }
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                self.closedLidActionInFlight = false
                switch result {
                case .success:
                    self.refresh()
                case .failure(let error):
                    self.refresh()
                    self.presentAlert(title: "Closed-Lid Mode failed", message: error.localizedDescription, style: .warning)
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

    private func confirmClosedLidEnable(currentValue: String, onContinue: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Turn On Lid-Closed Awake?"
        alert.informativeText = """
        AgentWake will request administrator permission to disable lid sleep via pmset disablesleep. This setting affects all apps system-wide.

        When you turn Lid-Closed Awake off, AgentWake will restore your previous value (currently: \(currentValue)).
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else {
                    return
                }
                onContinue()
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            onContinue()
        }
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

    private func startRefreshingWhileVisible() {
        guard refreshTimer == nil else {
            return
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func stopRefreshingWhileVisible() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
