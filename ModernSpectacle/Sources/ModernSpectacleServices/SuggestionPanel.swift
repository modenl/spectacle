import AppKit

/// A small floating prompt that never steals focus: one sentence, Accept, Dismiss. Hides itself after a few seconds.
@MainActor
public final class SuggestionPanel {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var onAccept: (() -> Void)?
    private var onDismiss: (() -> Void)?

    public init() {}

    public func show(
        message: String,
        acceptTitle: String,
        near frame: CGRect,
        timeout: TimeInterval = 10,
        onAccept: @escaping () -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        dismiss(notify: false)
        self.onAccept = onAccept
        self.onDismiss = onDismiss

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.preferredMaxLayoutWidth = 300

        let accept = NSButton(title: acceptTitle, target: self, action: #selector(acceptTapped))
        accept.keyEquivalent = "\r"
        accept.bezelStyle = .rounded
        let no = NSButton(title: "No", target: self, action: #selector(dismissTapped))
        no.bezelStyle = .rounded

        let buttons = NSStackView(views: [no, accept])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = stack
        panel.layoutIfNeeded()
        let size = stack.fittingSize
        panel.setContentSize(size)

        // Top-right corner of the display the windows are on. AX coordinates are top-left based; AppKit's are bottom-left.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin = NSPoint(x: frame.maxX - size.width - 20, y: screenHeight - frame.minY - size.height - 20)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.dismiss(notify: true)
        }
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    @objc private func acceptTapped() {
        let action = onAccept
        dismiss(notify: false)
        action?()
    }

    @objc private func dismissTapped() {
        dismiss(notify: true)
    }

    private func dismiss(notify: Bool) {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
        let callback = onDismiss
        onAccept = nil
        onDismiss = nil
        if notify {
            callback?()
        }
    }
}
