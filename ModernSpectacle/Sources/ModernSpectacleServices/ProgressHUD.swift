import AppKit

/// A small floating "working…" indicator with a spinner. Never takes focus.
@MainActor
public final class ProgressHUD {
    private var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var hideTask: Task<Void, Never>?

    public init() {}

    public func show(_ text: String, near frame: CGRect, spinning: Bool = true, autoHideAfter: TimeInterval? = nil) {
        hideTask?.cancel()
        label.stringValue = text
        label.preferredMaxLayoutWidth = 520
        spinner.isHidden = !spinning
        if panel == nil {
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            label.font = .systemFont(ofSize: 13)
            let stack = NSStackView(views: [spinner, label])
            stack.orientation = .horizontal
            stack.spacing = 8
            let content = NSView.padding(stack, NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 18))

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
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
            panel.ignoresMouseEvents = true
            panel.contentView = content
            self.panel = panel
        }
        guard let panel else { return }
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 240, height: 44)
        panel.setContentSize(size)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: screenHeight - frame.minY - size.height - 16))
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        panel.orderFrontRegardless()
        if let autoHideAfter {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(autoHideAfter))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    public func hide() {
        hideTask?.cancel()
        spinner.stopAnimation(nil)
        panel?.orderOut(nil)
        panel = nil
    }
}
