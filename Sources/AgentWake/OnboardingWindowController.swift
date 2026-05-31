import AppKit
import AgentWakeCore

@MainActor
final class OnboardingWindowController: NSWindowController {
    enum Response {
        case openSettings
        case done
    }

    private var response: Response = .done

    init(previews: [IntegrationPreview]) {
        let contentViewController = OnboardingViewController(previews: previews)
        let window = NSPanel(contentViewController: contentViewController)
        window.title = "Welcome to AgentWake"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 680, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)

        contentViewController.onOpenSettings = { [weak self] in
            self?.response = .openSettings
            NSApp.stopModal()
        }
        contentViewController.onDone = { [weak self] in
            self?.response = .done
            NSApp.stopModal()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func runFrontmostModal() -> Response {
        guard let window else {
            return .done
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.level = .modalPanel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.runModal(for: window)
        window.close()
        return response
    }
}

@MainActor
private final class OnboardingViewController: NSViewController {
    var onOpenSettings: (() -> Void)?
    var onDone: (() -> Void)?

    private let previews: [IntegrationPreview]

    init(previews: [IntegrationPreview]) {
        self.previews = previews
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "AgentWake")
        title.font = .preferredFont(forTextStyle: .title1)

        let step1 = stepLabel("1. AgentWake adds local hooks so Claude Code and Codex can report session activity.")
        let step2 = stepLabel("2. Lid-Closed Awake uses an installed helper, approved once in System Settings.")
        let step3 = stepLabel("3. Open Claude Code or Codex. AgentWake will catch the next session automatically.")

        let diffView = NSTextView()
        diffView.isEditable = false
        diffView.isSelectable = true
        diffView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        diffView.string = previewText()
        diffView.textContainerInset = NSSize(width: 10, height: 10)
        diffView.backgroundColor = .textBackgroundColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = diffView
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let openSettingsButton = NSButton(title: "Open Settings", target: self, action: #selector(openSettings))
        openSettingsButton.bezelStyle = .rounded
        let doneButton = NSButton(title: "Done", target: self, action: #selector(done))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), openSettingsButton, doneButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let stack = NSStackView(views: [title, step1, scroll, step2, step3, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 250),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48)
        ])
        view = root
    }

    private func stepLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .preferredFont(forTextStyle: .body)
        return label
    }

    private func previewText() -> String {
        previews.map { preview in
            var lines = [
                "\(preview.displayName)",
                "Config: \(preview.settingsFile.isEmpty ? "path unavailable" : preview.settingsFile)"
            ]
            if !preview.dryRunDiff.isEmpty {
                lines.append("Will change:")
                lines += preview.dryRunDiff.map { "  \($0)" }
            }
            if let failureReason = preview.failureReason {
                lines.append("Issue: \(failureReason)")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func done() {
        onDone?()
    }
}
