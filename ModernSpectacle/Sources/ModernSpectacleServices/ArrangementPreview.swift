import AppKit
import QuartzCore

/// The layout shown before it is applied: a translucent sheet over each display where every window is a card that flies
/// from where the window is now to the slot it will get. The motion happens here, in Core Animation; the real windows
/// only jump once, underneath the sheet, when the arrangement is committed. Moving real windows frame by frame through
/// Accessibility is too slow and uneven to animate.
@MainActor
public final class ArrangementPreview {
    public enum Role: Sendable {
        case main
        case tile
        case awareness
        case hidden
    }

    public struct Card: Sendable {
        public var id: Int
        public var app: String
        public var title: String
        public var pid: pid_t
        /// Accessibility coordinates (top-left origin on the main display).
        public var from: CGRect
        public var to: CGRect
        public var role: Role
        /// Cards start one after another in this order: main first, then by nearness.
        public var order: Int

        public init(id: Int, app: String, title: String, pid: pid_t, from: CGRect, to: CGRect, role: Role, order: Int) {
            self.id = id
            self.app = app
            self.title = title
            self.pid = pid
            self.from = from
            self.to = to
            self.role = role
            self.order = order
        }
    }

    public struct Caption: Sendable {
        public var text: String
        public var index: Int
        public var count: Int

        public init(text: String, index: Int, count: Int) {
            self.text = text
            self.index = index
            self.count = count
        }
    }

    private final class Sheet {
        let panel: NSPanel
        let root: CALayer
        let backdrop: NSVisualEffectView
        let skeleton = CALayer()
        let caption = CALayer()
        let captionText = CATextLayer()
        let dots = CALayer()
        /// Screen frame in Accessibility coordinates.
        let axFrame: CGRect
        var cards: [Int: CardLayer] = [:]

        init(panel: NSPanel, root: CALayer, backdrop: NSVisualEffectView, axFrame: CGRect) {
            self.panel = panel
            self.root = root
            self.backdrop = backdrop
            self.axFrame = axFrame
        }

        /// Accessibility rect (y down from the top of the main display) to this sheet's layer coordinates (y up from the
        /// bottom of this screen). Converted here rather than by flipping the root layer: AppKit owns the geometry of a
        /// view's backing layer and does not keep a flip set on it.
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX - axFrame.minX, y: axFrame.height - (rect.maxY - axFrame.minY), width: rect.width, height: rect.height)
        }

        var size: CGSize { axFrame.size }
    }

    private var sheets: [Sheet] = []
    private var hideTask: Task<Void, Never>?
    public private(set) var isVisible = false

    private static let flight: CFTimeInterval = 0.42
    private static let stagger: CFTimeInterval = 0.035

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    public init() {}

    // MARK: - Showing

    /// Cards fly from where the windows are to their targets; the template's slots fade in first as a skeleton.
    public func show(_ cards: [Card], caption: Caption) {
        hideTask?.cancel()
        tearDown()
        isVisible = true
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let axFrame = CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
            let mine = cards.filter { axFrame.contains(CGPoint(x: $0.to.midX, y: $0.to.midY)) }
            guard !mine.isEmpty else { continue }
            let sheet = makeSheet(on: screen, axFrame: axFrame)
            sheets.append(sheet)
            sheet.panel.orderFrontRegardless()
            fade(sheet.backdrop, to: 1, duration: 0.18)
            place(mine, on: sheet, morphing: false)
            setCaption(caption, on: sheet, animated: false)
        }
    }

    /// Switches to another layout: every card moves from wherever it is right now to its new target.
    public func update(_ cards: [Card], caption: Caption) {
        guard isVisible else { return show(cards, caption: caption) }
        for sheet in sheets {
            let mine = cards.filter { sheet.axFrame.contains(CGPoint(x: $0.to.midX, y: $0.to.midY)) }
            place(mine, on: sheet, morphing: true)
            setCaption(caption, on: sheet, animated: true)
        }
    }

    /// Runs `apply` (the real windows jump into place under the sheet), then fades the sheet away.
    public func commit(_ apply: @escaping () -> Void) {
        guard isVisible else { return apply() }
        apply()
        dismiss(after: 0.05, fade: 0.22)
    }

    /// The cards fly back to where the windows still are, then the sheet goes.
    public func cancel() {
        guard isVisible else { return }
        for sheet in sheets {
            for card in sheet.cards.values {
                animate(card, to: sheet.local(card.card.from), compact: false, delay: 0, duration: 0.25)
            }
        }
        dismiss(after: 0.22, fade: 0.15)
    }

    /// A short show for a single change (Bring to Main): animate, apply, fade.
    public func flash(_ cards: [Card], caption: Caption, apply: @escaping () -> Void) {
        show(cards, caption: caption)
        let wait = reduceMotion ? 0.12 : Self.flight + Self.stagger * Double(cards.count.clamped(to: 0...6))
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            commit(apply)
        }
    }

    // MARK: - Sheets

    private func makeSheet(on screen: NSScreen, axFrame: CGRect) -> Sheet {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.setFrame(screen.frame, display: false)

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        let backdrop = NSVisualEffectView(frame: content.bounds)
        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        backdrop.alphaValue = 0
        content.addSubview(backdrop)

        let host = NSView(frame: content.bounds)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        let root = host.layer!
        root.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        content.addSubview(host)
        panel.contentView = content

        let sheet = Sheet(panel: panel, root: root, backdrop: backdrop, axFrame: axFrame)
        root.addSublayer(sheet.skeleton)
        sheet.caption.isGeometryFlipped = true
        sheet.caption.zPosition = 100 // always above the cards
        sheet.caption.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        sheet.caption.cornerRadius = 18
        sheet.caption.shadowOpacity = 0.25
        sheet.caption.shadowRadius = 12
        sheet.captionText.contentsScale = screen.backingScaleFactor
        sheet.captionText.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        sheet.captionText.fontSize = 15
        sheet.captionText.alignmentMode = .center
        sheet.captionText.foregroundColor = NSColor.labelColor.cgColor
        sheet.caption.addSublayer(sheet.captionText)
        sheet.caption.addSublayer(sheet.dots)
        root.addSublayer(sheet.caption)
        return sheet
    }

    private func setCaption(_ caption: Caption, on sheet: Sheet, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        let width = max(240, CGFloat(caption.text.count) * 9 + 60)
        // Bottom center, just above the background tray: clear of the cards' title rows.
        sheet.caption.frame = CGRect(x: (sheet.size.width - width) / 2, y: 116, width: width, height: 58)
        sheet.captionText.string = caption.text
        sheet.captionText.frame = CGRect(x: 10, y: 10, width: width - 20, height: 22)
        sheet.dots.sublayers?.forEach { $0.removeFromSuperlayer() }
        let dotSize: CGFloat = 7
        let total = CGFloat(caption.count) * (dotSize + 8) - 8
        for index in 0..<caption.count {
            let dot = CALayer()
            dot.frame = CGRect(x: (width - total) / 2 + CGFloat(index) * (dotSize + 8), y: 39, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dot.backgroundColor = (index == caption.index ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
            sheet.dots.addSublayer(dot)
        }
        CATransaction.commit()
        if animated {
            let pulse = CASpringAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.94
            pulse.toValue = 1
            pulse.damping = 12
            pulse.duration = pulse.settlingDuration
            sheet.caption.add(pulse, forKey: "pulse")
        }
    }

    // MARK: - Cards

    private func place(_ cards: [Card], on sheet: Sheet, morphing: Bool) {
        drawSkeleton(for: cards, on: sheet, animated: morphing)
        let hidden = cards.filter { $0.role == .hidden }.sorted { $0.order < $1.order }
        let tray = trayFrames(count: hidden.count, in: sheet.size)
        let trayOf = Dictionary(uniqueKeysWithValues: zip(hidden.map(\.id), tray))

        for card in cards {
            let layer: CardLayer
            if let existing = sheet.cards[card.id] {
                layer = existing
                layer.card = card
            } else {
                layer = CardLayer(card: card, scale: sheet.panel.backingScaleFactor)
                layer.frame = sheet.local(card.from)
                sheet.root.insertSublayer(layer, below: sheet.caption)
                sheet.cards[card.id] = layer
            }
            let target = card.role == .hidden ? trayOf[card.id]! : sheet.local(card.to).insetBy(dx: 6, dy: 6)
            let delay = reduceMotion ? 0 : Self.stagger * Double(min(card.order, 8))
            animate(layer, to: target, compact: card.role == .hidden, delay: delay, duration: Self.flight)
            layer.zPosition = card.role == .main ? 10 : (card.role == .hidden ? 0 : 5)
        }
        // Windows no longer shown on this sheet (moved to another display's sheet) fade out.
        let keep = Set(cards.map(\.id))
        for (id, layer) in sheet.cards where !keep.contains(id) {
            layer.removeFromSuperlayer()
            sheet.cards[id] = nil
        }
    }

    /// The template's slots as faint outlines, so the shape of the layout is visible before the cards land.
    private func drawSkeleton(for cards: [Card], on sheet: Sheet, animated: Bool) {
        sheet.skeleton.sublayers?.forEach { $0.removeFromSuperlayer() }
        for card in cards where card.role != .hidden {
            let outline = CAShapeLayer()
            let rect = sheet.local(card.to).insetBy(dx: 4, dy: 4)
            outline.path = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: 14, cornerHeight: 14, transform: nil)
            outline.frame = rect
            outline.fillColor = (card.role == .awareness ? NSColor.systemTeal : NSColor.controlAccentColor).withAlphaComponent(0.08).cgColor
            outline.strokeColor = (card.role == .awareness ? NSColor.systemTeal : NSColor.controlAccentColor).withAlphaComponent(0.55).cgColor
            outline.lineWidth = card.role == .main ? 2.5 : 1.5
            outline.lineDashPattern = card.role == .main ? nil : [8, 6]
            sheet.skeleton.addSublayer(outline)
            if !reduceMotion {
                let appear = CABasicAnimation(keyPath: "opacity")
                appear.fromValue = 0
                appear.toValue = 1
                appear.duration = animated ? 0.2 : 0.3
                outline.add(appear, forKey: "appear")
            }
        }
    }

    /// Hidden windows shrink into a row of icons along the bottom: the "background" tray.
    private func trayFrames(count: Int, in screen: CGSize) -> [CGRect] {
        let size: CGFloat = 64
        let gap: CGFloat = 14
        let width = CGFloat(count) * size + CGFloat(max(count - 1, 0)) * gap
        return (0..<count).map { index in
            CGRect(x: (screen.width - width) / 2 + CGFloat(index) * (size + gap), y: 36, width: size, height: size)
        }
    }

    private func animate(_ layer: CardLayer, to target: CGRect, compact: Bool, delay: CFTimeInterval, duration: CFTimeInterval) {
        let start = layer.presentation()?.frame ?? layer.frame
        layer.removeAllAnimations()
        let watermarkStart = layer.watermarkPresentationFrame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = target
        layer.setCompact(compact)
        CATransaction.commit()
        guard !reduceMotion else {
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = 0.15
            layer.add(fadeIn, forKey: "fade")
            return
        }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        for (key, from, to) in [
            ("position", NSValue(point: CGPoint(x: start.midX, y: start.midY)), NSValue(point: CGPoint(x: target.midX, y: target.midY))),
            ("bounds.size", NSValue(size: start.size), NSValue(size: target.size)),
        ] {
            let spring = CASpringAnimation(keyPath: key)
            spring.fromValue = from
            spring.toValue = to
            spring.mass = 1
            spring.stiffness = 170
            spring.damping = 20
            spring.duration = max(duration, spring.settlingDuration * 0.8)
            spring.beginTime = now + delay
            spring.fillMode = .backwards
            layer.add(spring, forKey: key)
        }
        layer.animateWatermark(from: watermarkStart, beginTime: now + delay, duration: duration)
        if layer.card.role == .main {
            // The main window lands with a small bounce, so the eye follows it.
            let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
            bounce.values = [1, 1.035, 1]
            bounce.keyTimes = [0, 0.4, 1]
            bounce.duration = 0.28
            bounce.beginTime = now + delay + duration * 0.75
            layer.add(bounce, forKey: "bounce")
        }
    }

    // MARK: - Hiding

    private func fade(_ view: NSView, to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            view.animator().alphaValue = alpha
        }
    }

    private func dismiss(after delay: TimeInterval, fade duration: TimeInterval) {
        hideTask?.cancel()
        let sheets = self.sheets
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            for sheet in sheets {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = duration
                    sheet.panel.animator().alphaValue = 0
                }, completionHandler: nil)
            }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.tearDown()
        }
        isVisible = false
    }

    private func tearDown() {
        for sheet in sheets { sheet.panel.orderOut(nil) }
        sheets = []
    }
}

/// One window as a card: rounded, with the app's icon, name and window title at the top, like a title bar. In the
/// background tray it collapses to just the icon.
private final class CardLayer: CALayer {
    var card: ArrangementPreview.Card
    private let icon = CALayer()
    /// The app's icon, large and faint in the middle of the card, so each card is recognizable at a glance.
    private let watermark = CALayer()
    private let appName = CATextLayer()
    private let subtitle = CATextLayer()

    init(card: ArrangementPreview.Card, scale: CGFloat) {
        self.card = card
        super.init()
        isGeometryFlipped = true
        cornerRadius = 12
        masksToBounds = false
        shadowOffset = CGSize(width: 0, height: -6)
        applyRole()

        let image = NSRunningApplication(processIdentifier: card.pid)?.icon
        icon.contents = image?.layerContents(forContentsScale: scale)
        icon.contentsGravity = .resizeAspect
        icon.frame = CGRect(x: 14, y: 12, width: 34, height: 34)
        watermark.contents = icon.contents
        watermark.contentsGravity = .resizeAspect
        watermark.opacity = 0.22
        addSublayer(watermark)
        addSublayer(icon)
        for (layer, text, size, weight, color) in [
            (appName, card.app, CGFloat(14), NSFont.Weight.semibold, NSColor.labelColor),
            (subtitle, card.title, CGFloat(12), NSFont.Weight.regular, NSColor.secondaryLabelColor),
        ] {
            layer.string = text
            layer.font = NSFont.systemFont(ofSize: size, weight: weight)
            layer.fontSize = size
            layer.foregroundColor = color.cgColor
            layer.truncationMode = .end
            layer.contentsScale = scale
            addSublayer(layer)
        }
        appName.frame = CGRect(x: 58, y: 12, width: 400, height: 18)
        subtitle.frame = CGRect(x: 58, y: 31, width: 400, height: 16)
    }

    override init(layer: Any) {
        card = (layer as? CardLayer)?.card ?? ArrangementPreview.Card(id: 0, app: "", title: "", pid: 0, from: .zero, to: .zero, role: .tile, order: 0)
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var watermarkPresentationFrame: CGRect {
        watermark.presentation()?.frame ?? watermark.frame
    }

    /// Centered, a third of the card's smaller side, at most 180 points; gone in the tray.
    private func watermarkFrame(for size: CGSize, compact: Bool) -> CGRect {
        let side = compact ? 0 : min(min(size.width, size.height) * 0.34, 180)
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
    }

    /// The watermark stays centered while the card's size springs, instead of jumping to its final place.
    func animateWatermark(from start: CGRect, beginTime: CFTimeInterval, duration: CFTimeInterval) {
        let target = watermark.frame
        for (key, from, to) in [
            ("position", NSValue(point: CGPoint(x: start.midX, y: start.midY)), NSValue(point: CGPoint(x: target.midX, y: target.midY))),
            ("bounds.size", NSValue(size: start.size), NSValue(size: target.size)),
        ] {
            let spring = CASpringAnimation(keyPath: key)
            spring.fromValue = from
            spring.toValue = to
            spring.stiffness = 170
            spring.damping = 20
            spring.duration = max(duration, spring.settlingDuration * 0.8)
            spring.beginTime = beginTime
            spring.fillMode = .backwards
            watermark.add(spring, forKey: key)
        }
    }

    /// Icon only, centered, for the tray; full header otherwise. Text widths follow the card.
    func setCompact(_ compact: Bool) {
        watermark.frame = watermarkFrame(for: bounds.size, compact: compact)
        appName.opacity = compact ? 0 : 1
        subtitle.opacity = compact ? 0 : 1
        icon.frame = compact ? CGRect(x: (bounds.width - 40) / 2, y: (bounds.height - 40) / 2, width: 40, height: 40) : CGRect(x: 14, y: 12, width: 34, height: 34)
        let textWidth = max(bounds.width - 72, 40)
        appName.frame.size.width = textWidth
        subtitle.frame.size.width = textWidth
        applyRole()
    }

    /// Main glows in the accent color, awareness cards are tinted teal, the rest are plain window-colored cards.
    private func applyRole() {
        let tint: NSColor = switch card.role {
        case .main: .controlAccentColor
        case .awareness: .systemTeal
        case .tile, .hidden: .windowBackgroundColor
        }
        backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: card.role == .tile || card.role == .hidden ? 0 : 0.08, of: tint)?.withAlphaComponent(0.95).cgColor
        borderColor = (card.role == .main ? NSColor.controlAccentColor : card.role == .awareness ? NSColor.systemTeal.withAlphaComponent(0.7) : NSColor.separatorColor).cgColor
        borderWidth = card.role == .main ? 2.5 : 1
        shadowColor = (card.role == .main ? NSColor.controlAccentColor : NSColor.black).cgColor
        shadowOpacity = card.role == .main ? 0.55 : 0.28
        shadowRadius = card.role == .main ? 28 : 18
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
