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
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let launchAtLoginStatusLabel = NSTextField(labelWithString: "")
    private let closedLidModeStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let closedLidSafetyWarningLabel = NSTextField(wrappingLabelWithString: "")
    private let claudeStatusLabel = NSTextField(labelWithString: "")
    private let codexStatusLabel = NSTextField(labelWithString: "")
    private let claudeEnabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let codexEnabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let claudeDetailsButton = NSButton(title: "Show details", target: nil, action: nil)
    private let codexDetailsButton = NSButton(title: "Show details", target: nil, action: nil)
    private let claudeDetailsLabel = NSTextField(wrappingLabelWithString: "")
    private let codexDetailsLabel = NSTextField(wrappingLabelWithString: "")
    private let claudeRemoveButton = NSButton(title: "Remove", target: nil, action: nil)
    private let codexRemoveButton = NSButton(title: "Remove", target: nil, action: nil)
    private let protectButton = NSButton(title: "Keep sessions awake", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Resume Sleep Protection", target: nil, action: nil)
    private let pauseOptionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let enableClosedLidButton = NSButton(title: "Turn On", target: nil, action: nil)
    private let disableClosedLidButton = NSButton(title: "Turn Off", target: nil, action: nil)
    private let repairButton = NSButton(title: "Reinstall agent hooks", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let showEventLogButton = NSButton(title: "Show event log...", target: nil, action: nil)
    private let revealEventLogButton = NSButton(title: "Reveal log in Finder", target: nil, action: nil)
    private let copyDiagnosticsButton = NSButton(title: "Copy diagnostic info", target: nil, action: nil)
    private let uninstallButton = NSButton(title: "Uninstall AgentWake...", target: nil, action: nil)
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

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)
        launchAtLoginCheckbox.setAccessibilityLabel("Launch AgentWake at login")
        launchAtLoginStatusLabel.textColor = .secondaryLabelColor

        statusLabel.font = .preferredFont(forTextStyle: .title3)
        statusLabel.setAccessibilityLabel("AgentWake runtime status")
        sessionListLabel.textColor = .secondaryLabelColor
        sessionListLabel.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        sessionListLabel.maximumNumberOfLines = 12
        sessionListLabel.setAccessibilityLabel("Detected agent sessions")

        closedLidModeStatusLabel.textColor = .secondaryLabelColor
        closedLidModeStatusLabel.setAccessibilityLabel("Closed-Lid Mode status")
        closedLidSafetyWarningLabel.stringValue = "Warning: Battery & thermal cutoffs are not yet enforced. For long overnight runs on battery, plug into AC."
        closedLidSafetyWarningLabel.textColor = .systemOrange
        closedLidSafetyWarningLabel.isHidden = true
        closedLidSafetyWarningLabel.setAccessibilityLabel("Lid-Closed Awake safety warning")

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

        claudeEnabledCheckbox.target = self
        claudeEnabledCheckbox.action = #selector(toggleClaudeEnabled)
        claudeEnabledCheckbox.setAccessibilityLabel("Enable Claude Code integration")

        codexEnabledCheckbox.target = self
        codexEnabledCheckbox.action = #selector(toggleCodexEnabled)
        codexEnabledCheckbox.setAccessibilityLabel("Enable Codex CLI integration")

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
            integrationRow(title: claudeTitle, enabledCheckbox: claudeEnabledCheckbox, status: claudeStatusLabel, detailsButton: claudeDetailsButton, removeButton: claudeRemoveButton),
            claudeDetailsLabel,
            integrationRow(title: codexTitle, enabledCheckbox: codexEnabledCheckbox, status: codexStatusLabel, detailsButton: codexDetailsButton, removeButton: codexRemoveButton),
            codexDetailsLabel
        ])
        integrationStack.orientation = .vertical
        integrationStack.alignment = .leading
        integrationStack.spacing = 6

        protectButton.target = self
        protectButton.action = #selector(protectDetectedSessions)
        protectButton.bezelStyle = .rounded
        protectButton.setAccessibilityLabel("Keep detected sessions awake")

        pauseButton.target = self
        pauseButton.action = #selector(toggleSleepProtectionPause)
        pauseButton.bezelStyle = .rounded
        pauseButton.setAccessibilityLabel("Resume sleep protection")

        configurePauseOptionsButton()

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

        showEventLogButton.target = self
        showEventLogButton.action = #selector(showEventLog)
        showEventLogButton.bezelStyle = .rounded
        showEventLogButton.setAccessibilityLabel("Show event log")

        revealEventLogButton.target = self
        revealEventLogButton.action = #selector(revealEventLog)
        revealEventLogButton.bezelStyle = .rounded
        revealEventLogButton.setAccessibilityLabel("Reveal event log in Finder")

        copyDiagnosticsButton.target = self
        copyDiagnosticsButton.action = #selector(copyDiagnosticInfo)
        copyDiagnosticsButton.bezelStyle = .rounded
        copyDiagnosticsButton.setAccessibilityLabel("Copy diagnostic info")

        uninstallButton.target = self
        uninstallButton.action = #selector(uninstallAgentWake)
        uninstallButton.bezelStyle = .rounded
        uninstallButton.setAccessibilityLabel("Uninstall AgentWake")

        let sessionButtons = rowStack([protectButton, pauseOptionsButton, pauseButton, refreshButton])
        let closedLidButtons = rowStack([enableClosedLidButton, disableClosedLidButton])
        let generalStack = rowStack([launchAtLoginCheckbox, launchAtLoginStatusLabel])
        let supportButtons = rowStack([showEventLogButton, revealEventLogButton, copyDiagnosticsButton, uninstallButton])
        let footerButtons = rowStack([NSView(), closeButton])

        let stack = NSStackView(views: [
            titleLabel,
            sectionHeader("General"),
            generalStack,
            separator(),
            sectionHeader("Sessions"),
            statusLabel,
            sessionListLabel,
            sessionButtons,
            separator(),
            sectionHeader("Lid-Closed Awake"),
            closedLidModeStatusLabel,
            closedLidSafetyWarningLabel,
            closedLidButtons,
            separator(),
            sectionHeader("Integrations"),
            integrationStack,
            repairButton,
            separator(),
            sectionHeader("Support"),
            supportButtons,
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
            generalStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            integrationStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            supportButtons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
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

        launchAtLoginCheckbox.state = LaunchAtLoginController.isEnabled ? .on : .off
        launchAtLoginStatusLabel.stringValue = LaunchAtLoginController.statusText

        let protectableCount = services.agentMonitor.protectableDetectedSessionCount
        statusLabel.stringValue = services.agentMonitor.sessionSummaryMessage()
        sessionListLabel.stringValue = services.agentMonitor.sessionDetailMessage()
        protectButton.title = protectButtonTitle(count: protectableCount)
        protectButton.isEnabled = protectableCount > 0
        pauseButton.isHidden = !isSleepProtectionPaused
        pauseOptionsButton.isHidden = isSleepProtectionPaused
        refreshButton.isHidden = !isStatusStale()

        let closedLidStatus = services.closedLidModeController.status()
        closedLidModeStatusLabel.stringValue = closedLidDisplayText(for: closedLidStatus)
        closedLidSafetyWarningLabel.isHidden = !shouldShowSafetyWarning(status: closedLidStatus)
        enableClosedLidButton.isEnabled = !closedLidActionInFlight &&
            canEnableClosedLidMode(status: closedLidStatus)
        disableClosedLidButton.isEnabled = !closedLidActionInFlight &&
            canDisableClosedLidMode(status: closedLidStatus)

        let snapshots = Dictionary(
            uniqueKeysWithValues: services.integrationManager.snapshots().map { ($0.agentID, $0) }
        )
        let previews = Dictionary(
            uniqueKeysWithValues: services.integrationManager.installPreviews().map { ($0.agentID, $0) }
        )
        claudeStatusLabel.stringValue = statusText(for: snapshots["claude-code"])
        codexStatusLabel.stringValue = statusText(for: snapshots["codex-cli"])
        claudeEnabledCheckbox.state = agentEnabledState(agentID: "claude-code") ? .on : .off
        codexEnabledCheckbox.state = agentEnabledState(agentID: "codex-cli") ? .on : .off
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

    private func configurePauseOptionsButton() {
        pauseOptionsButton.removeAllItems()
        pauseOptionsButton.addItem(withTitle: "Pause Sleep Protection")
        pauseOptionsButton.menu?.items.first?.isEnabled = false
        addPauseOption("Pause for 30 minutes", tag: 30 * 60)
        addPauseOption("Pause for 1 hour", tag: 60 * 60)
        addPauseOption("Pause for 4 hours", tag: 4 * 60 * 60)
        addPauseOption("Pause until tomorrow morning", tag: -1)
        addPauseOption("Pause indefinitely", tag: 0)
        pauseOptionsButton.target = self
        pauseOptionsButton.action = #selector(selectPauseOption(_:))
        pauseOptionsButton.setAccessibilityLabel("Pause sleep protection")
    }

    private func addPauseOption(_ title: String, tag: Int) {
        pauseOptionsButton.addItem(withTitle: title)
        pauseOptionsButton.lastItem?.tag = tag
    }

    private func integrationRow(
        title: NSTextField,
        enabledCheckbox: NSButton,
        status: NSTextField,
        detailsButton: NSButton,
        removeButton: NSButton
    ) -> NSStackView {
        let spacer = NSView()
        let stack = rowStack([detailsButton, title, enabledCheckbox, spacer, status, removeButton])
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        return stack
    }

    private func agentEnabledState(agentID: String) -> Bool {
        services.settingsStore.settings.agents.first(where: { $0.id == agentID })?.isEnabled ?? false
    }

    private func protectButtonTitle(count: Int) -> String {
        guard count > 0 else {
            return "Keep sessions awake"
        }

        return count == 1 ? "Also keep 1 detected session awake" : "Also keep \(count) detected sessions awake"
    }

    private func closedLidDisplayText(for status: ClosedLidStatus) -> String {
        switch status {
        case .off:
            return "Off"
        case .enabledByAgentWake:
            return "Enabled\nAgentWake will restore the previous sleep setting when this is disabled."
        case .ownershipPending:
            return "Finishing setup\nDisable is blocked until AgentWake confirms ownership."
        case .enabledByOther:
            return "Disabled by another tool\nAgentWake left it alone so it can be restored cleanly when you turn that tool off."
        case .unknown(let reason):
            return "Status unknown\n\(reason)"
        }
    }

    private func canEnableClosedLidMode(status: ClosedLidStatus) -> Bool {
        switch status {
        case .off, .unknown:
            return true
        case .enabledByAgentWake, .enabledByOther, .ownershipPending:
            return false
        }
    }

    private func canDisableClosedLidMode(status: ClosedLidStatus) -> Bool {
        status == .enabledByAgentWake
    }

    private func shouldShowSafetyWarning(status: ClosedLidStatus) -> Bool {
        status == .enabledByAgentWake
    }

    private var isSleepProtectionPaused: Bool {
        services.agentMonitor.aggregateHoldState.isPaused
    }

    private func isStatusStale(referenceDate: Date = Date()) -> Bool {
        guard let lastPollAt = services.agentMonitor.lastPollAt else {
            return true
        }

        return referenceDate.timeIntervalSince(lastPollAt) > 30
    }

    private func presentAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            beginFrontmostSheet(alert, for: window) { _ in }
        } else {
            runFrontmostAlert(alert)
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

    @objc private func toggleClaudeEnabled() {
        setAgentEnabled(agentID: "claude-code", displayName: "Claude Code", isEnabled: claudeEnabledCheckbox.state == .on)
    }

    @objc private func toggleCodexEnabled() {
        setAgentEnabled(agentID: "codex-cli", displayName: "Codex CLI", isEnabled: codexEnabledCheckbox.state == .on)
    }

    private func setAgentEnabled(agentID: String, displayName: String, isEnabled: Bool) {
        do {
            try services.settingsStore.setAgentEnabled(agentID: agentID, isEnabled: isEnabled)
            services.agentMonitor.poll()
            services.assertionManager.reconcile()
            refresh()
        } catch {
            presentAlert(title: "Could not update \(displayName)", message: error.localizedDescription, style: .warning)
            refresh()
        }
    }

    @objc private func toggleSleepProtectionPause() {
        do {
            if isSleepProtectionPaused {
                try services.settingsStore.resumeSleepProtection()
            }
            services.agentMonitor.poll()
            services.assertionManager.reconcile()
            refresh()
        } catch {
            presentAlert(title: "Could not update sleep protection", message: error.localizedDescription, style: .warning)
        }
    }

    @objc private func selectPauseOption(_ sender: NSPopUpButton) {
        guard let selectedItem = sender.selectedItem, selectedItem.tag != 0 || selectedItem.title == "Pause indefinitely" else {
            sender.selectItem(at: 0)
            return
        }

        do {
            try services.settingsStore.pauseSleepProtection(until: pauseExpiration(forTag: selectedItem.tag, from: Date()))
            services.agentMonitor.poll()
            services.assertionManager.reconcile()
            refresh()
        } catch {
            presentAlert(title: "Could not pause sleep protection", message: error.localizedDescription, style: .warning)
        }
        sender.selectItem(at: 0)
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

    @objc private func toggleLaunchAtLogin() {
        let shouldEnable = launchAtLoginCheckbox.state == .on
        do {
            try LaunchAtLoginController.setEnabled(shouldEnable)
            try services.settingsStore.setLaunchAtLogin(LaunchAtLoginController.isEnabled)
            refresh()
        } catch {
            try? services.settingsStore.setLaunchAtLogin(LaunchAtLoginController.isEnabled)
            presentAlert(title: "Could not update login item", message: error.localizedDescription, style: .warning)
            refresh()
        }
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
            beginFrontmostSheet(alert, for: window) { response in
                guard response == .alertFirstButtonReturn else {
                    return
                }
                runRemoval()
            }
        } else if runFrontmostAlert(alert) == .alertFirstButtonReturn {
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
        alert.informativeText = closedLidEnableConfirmationText(currentValue: currentValue)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        if let window = view.window {
            beginFrontmostSheet(alert, for: window) { response in
                guard response == .alertFirstButtonReturn else {
                    return
                }
                onContinue()
            }
        } else if runFrontmostAlert(alert) == .alertFirstButtonReturn {
            onContinue()
        }
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
                beginFrontmostSheet(alert, for: window) { _ in }
            } else {
                runFrontmostAlert(alert)
            }
        }
    }

    private func beginFrontmostSheet(
        _ alert: NSAlert,
        for window: NSWindow,
        completionHandler: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: window, completionHandler: completionHandler)
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

    @objc private func refreshAction() {
        services.agentMonitor.poll()
        services.assertionManager.reconcile()
        refresh()
    }

    @objc private func showEventLog() {
        NSWorkspace.shared.open(services.logStore.auditLogURL)
    }

    @objc private func revealEventLog() {
        NSWorkspace.shared.activateFileViewerSelecting([services.logStore.auditLogURL])
    }

    @objc private func copyDiagnosticInfo() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(services.diagnosticInfo(), forType: .string)
    }

    @objc private func uninstallAgentWake() {
        let alert = NSAlert()
        alert.messageText = "Uninstall AgentWake?"
        alert.informativeText = "AgentWake will remove its Claude Code and Codex hooks, restore AgentWake-owned Lid-Closed Awake state, and attempt helper cleanup. The app bundle itself is left for you to delete from Applications."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        let runUninstall = { [weak self] in
            guard let self else {
                return
            }

            var results: [String] = []
            do {
                try self.services.integrationManager.removeAllIntegrations(at: Date())
                results.append("Agent hooks removed.")
            } catch {
                results.append("Agent hooks: \(error.localizedDescription)")
            }

            do {
                results.append(try self.services.closedLidModeController.uninstall())
            } catch {
                results.append("Lid-Closed Awake: \(error.localizedDescription)")
            }

            results.append("Production helper: no production helper is installed.")
            self.services.agentMonitor.poll()
            self.services.assertionManager.reconcile()
            self.refresh()
            self.presentAlert(title: "Uninstall cleanup complete", message: results.joined(separator: "\n"))
        }

        if let window = view.window {
            beginFrontmostSheet(alert, for: window) { response in
                guard response == .alertFirstButtonReturn else {
                    return
                }
                runUninstall()
            }
        } else if runFrontmostAlert(alert) == .alertFirstButtonReturn {
            runUninstall()
        }
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
