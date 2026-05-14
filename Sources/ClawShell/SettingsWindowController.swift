import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let contentViewController = SettingsViewController()
        let window = NSWindow(contentViewController: contentViewController)
        window.title = "ClawShell Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 440, height: 260))
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
    override func loadView() {
        let rootView = NSView()
        rootView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "ClawShell Settings")
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.setAccessibilityLabel("ClawShell Settings")

        let subtitleLabel = NSTextField(
            wrappingLabelWithString: "Core controls will appear here as agent detection, integrations, and sleep assertions land."
        )
        subtitleLabel.textColor = .secondaryLabelColor

        let sleepProtectionCheckbox = NSButton(
            checkboxWithTitle: "Enable normal sleep protection",
            target: nil,
            action: nil
        )
        sleepProtectionCheckbox.state = .on
        sleepProtectionCheckbox.setAccessibilityLabel("Enable normal sleep protection")

        let launchAtLoginCheckbox = NSButton(
            checkboxWithTitle: "Launch ClawShell at login",
            target: nil,
            action: nil
        )
        launchAtLoginCheckbox.setAccessibilityLabel("Launch ClawShell at login")

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.setAccessibilityLabel("Close settings")

        let controlsStack = NSStackView(views: [
            sleepProtectionCheckbox,
            launchAtLoginCheckbox
        ])
        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 8

        let buttonStack = NSStackView(views: [closeButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .trailing
        buttonStack.distribution = .gravityAreas

        let stack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            controlsStack,
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
    }

    @objc private func closeWindow() {
        view.window?.close()
        NSApp.setActivationPolicy(.accessory)
    }
}
