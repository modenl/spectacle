import AppKit
import ModernSpectacleCore
import QuartzCore

/// The layout about to be applied, as a small, almost transparent map in the middle of the screen: every display drawn
/// to scale and the template's slots as glass blocks. Switching template morphs the blocks into the new shape; nothing
/// says which app goes where, because while the model is still ranking nobody knows yet. The real windows stay in view
/// around the map and move once, when the arrangement is committed.
///
/// While the model is ranking, a glow runs around the map's edge.
@MainActor
public final class ArrangementPreview {
    public enum Role: Sendable {
        case main
        case tile
        case awareness
    }

    /// One slot as a block. Blocks with the same key in two consecutive states are the same block: it morphs from one
    /// place to the other. New keys grow in, keys that are gone shrink away.
    public struct Slot: Sendable {
        public var key: String
        /// Accessibility coordinates (top-left origin on the main display).
        public var rect: CGRect
        public var role: Role

        public init(key: String, rect: CGRect, role: Role) {
            self.key = key
            self.rect = rect
            self.role = role
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

    /// The map: one small panel showing all displays to scale.
    private final class Map {
        let panel: NSPanel
        let root: CALayer
        let glow = GlowLayer()
        let caption = CaptionLayer()
        /// The union of all displays, in Accessibility coordinates.
        let world: CGRect
        let scale: CGFloat
        /// Where the world is drawn inside the panel (layer coordinates, y up).
        let area: CGRect
        var blocks: [String: BlockLayer] = [:]

        init(panel: NSPanel, root: CALayer, world: CGRect, scale: CGFloat, area: CGRect) {
            self.panel = panel
            self.root = root
            self.world = world
            self.scale = scale
            self.area = area
        }

        /// Accessibility rect (y down from the top of the main display) to the map's layer coordinates (y up).
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: area.minX + (rect.minX - world.minX) * scale,
                   y: area.minY + (world.maxY - rect.maxY) * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }
    }

    private var map: Map?
    private var hideTask: Task<Void, Never>?
    private var commitID: UUID?
    public private(set) var isVisible = false

    /// How long a block's morph takes.
    public static let flight: CFTimeInterval = 0.42
    private static let stagger: CFTimeInterval = 0.035
    private static let mapSize = CGSize(width: 380, height: 210)
    private static let padding: CGFloat = 16
    private static let captionHeight: CGFloat = 40

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    public init() {}

    // MARK: - Showing

    /// Shows the slots, morphing from whatever is on the map now. `near` picks the display the map appears on.
    public func present(slots: [Slot], caption: Caption, waiting: Bool, near: CGRect? = nil) {
        hideTask?.cancel()
        show(slots: slots, caption: caption, waiting: waiting, near: near)
    }

    /// `present` without cancelling a pending hide or commit (Bring to Main's second step runs inside that task).
    private func show(slots: [Slot], caption: Caption, waiting: Bool, near: CGRect? = nil) {
        if !isVisible || map == nil {
            map?.panel.orderOut(nil)
            map = makeMap(near: near ?? slots.first { $0.role == .main }?.rect)
            isVisible = true
        }
        guard let map else { return }
        morph(to: slots, on: map)
        map.caption.show(caption, waiting: waiting, width: map.root.bounds.width)
        map.glow.setActive(waiting && !reduceMotion)
    }

    /// Runs `apply`, which moves the real windows and calls `done` once the visible ones are in place; the map fades
    /// then, or after 0.6 s at the latest so one slow app cannot hold it up.
    public func commit(_ apply: @escaping (_ done: @escaping @MainActor () -> Void) -> Void) {
        guard isVisible else { return apply {} }
        isVisible = false
        let id = UUID()
        commitID = id
        apply { [weak self] in
            guard let self, commitID == id else { return }
            commitID = nil
            dismiss(after: 0.02, fade: 0.2)
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, commitID == id else { return }
            commitID = nil
            dismiss(after: 0, fade: 0.2)
        }
    }

    /// The blocks shrink away, then the map goes; nothing moved.
    public func cancel() {
        guard isVisible, let map else { return }
        map.glow.setActive(false)
        for block in map.blocks.values { shrinkAway(block) }
        dismiss(after: 0.18, fade: 0.15)
    }

    /// A single change (Bring to Main): show `before`, morph to `after`, apply, fade.
    public func flash(from before: [Slot], to after: [Slot], caption: Caption, apply: @escaping (_ done: @escaping @MainActor () -> Void) -> Void) {
        present(slots: before, caption: caption, waiting: false)
        let still = reduceMotion
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(still ? 0 : 160))
            guard !Task.isCancelled, let self else { return }
            show(slots: after, caption: caption, waiting: false)
            try? await Task.sleep(for: .seconds(still ? 0.1 : Self.flight + 0.1))
            guard !Task.isCancelled else { return }
            commit(apply)
        }
    }

    // MARK: - The map

    /// A small frosted panel centered on the display the arrangement is about, with every display drawn to scale.
    private func makeMap(near target: CGRect?) -> Map {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenFrames = NSScreen.screens.map { screen in
            (screen, CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height))
        }
        let world = screenFrames.map(\.1).reduce(CGRect.null) { $0.union($1) }
        let scale = min(Self.mapSize.width / world.width, Self.mapSize.height / world.height)
        let mapWidth = (world.width * scale).rounded(), mapHeight = (world.height * scale).rounded()
        let panelSize = CGSize(width: mapWidth + Self.padding * 2, height: mapHeight + Self.padding * 2 + Self.captionHeight)
        let area = CGRect(x: Self.padding, y: Self.padding + Self.captionHeight, width: mapWidth, height: mapHeight)

        let anchor = target.flatMap { t in screenFrames.first { $0.1.contains(CGPoint(x: t.midX, y: t.midY)) }?.0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let origin = CGPoint(x: anchor.frame.midX - panelSize.width / 2, y: anchor.frame.midY - panelSize.height / 2)
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Nearly transparent frosted glass: the windows behind stay readable through it.
        let content = NSView(frame: CGRect(origin: .zero, size: panelSize))
        content.wantsLayer = true
        content.layer?.cornerRadius = 22
        content.layer?.masksToBounds = true
        let glass = NSVisualEffectView(frame: content.bounds)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.alphaValue = 0.85
        glass.autoresizingMask = [.width, .height]
        content.addSubview(glass)
        let host = NSView(frame: content.bounds)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layerUsesCoreImageFilters = true // the glow's blur
        content.addSubview(host)
        panel.contentView = content
        let root = host.layer!
        // A smoky tint: still see-through, but white text and blocks read over light windows too.
        root.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        root.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        root.borderWidth = 1
        root.cornerRadius = 22

        let map = Map(panel: panel, root: root, world: world, scale: scale, area: area)
        for (_, frame) in screenFrames {
            let screen = CAShapeLayer()
            let rect = map.local(frame).insetBy(dx: 1, dy: 1)
            screen.frame = rect
            screen.path = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: 6, cornerHeight: 6, transform: nil)
            screen.fillColor = NSColor.white.withAlphaComponent(0.04).cgColor
            screen.strokeColor = NSColor.white.withAlphaComponent(0.2).cgColor
            screen.lineWidth = 1
            root.addSublayer(screen)
        }
        map.glow.frame = CGRect(origin: .zero, size: panelSize)
        map.glow.zPosition = 90
        map.glow.configure(size: panelSize, cornerRadius: 22)
        root.addSublayer(map.glow)
        map.caption.zPosition = 100
        map.caption.configure(scale: anchor.backingScaleFactor)
        map.caption.frame = CGRect(x: 0, y: Self.padding - 4, width: panelSize.width, height: Self.captionHeight)
        root.addSublayer(map.caption)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        if !reduceMotion {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.92
            pop.toValue = 1
            pop.damping = 14
            pop.duration = pop.settlingDuration
            content.layer?.add(pop, forKey: "pop")
        }
        return map
    }

    // MARK: - Blocks

    /// Same key: the block morphs to its new place. New key: it grows out of the nearest block (or its own center).
    /// Key gone: it shrinks away. Main moves first, then by order.
    private func morph(to slots: [Slot], on map: Map) {
        let previous = map.blocks
        var next: [String: BlockLayer] = [:]
        for (order, slot) in slots.enumerated() {
            let target = map.local(slot.rect).insetBy(dx: 2, dy: 2)
            let delay = reduceMotion ? 0 : Self.stagger * Double(min(order, 8))
            if let block = previous[slot.key] {
                block.role = slot.role
                block.zPosition = slot.role == .main ? 10 : 5
                fly(block, to: target, order: order, delay: delay)
                next[slot.key] = block
            } else {
                let block = BlockLayer(role: slot.role)
                // Grow out of the block that is closest, so a new slot looks split off rather than popping up.
                let seed = previous.values.min { distance($0.frame, target) < distance($1.frame, target) }?.presentation()?.frame
                block.frame = seed.map { CGRect(x: $0.midX, y: $0.midY, width: 0, height: 0) } ?? CGRect(x: target.midX, y: target.midY, width: 0, height: 0)
                block.zPosition = slot.role == .main ? 10 : 5
                map.root.insertSublayer(block, below: map.glow)
                fly(block, to: target, order: order, delay: delay)
                next[slot.key] = block
            }
        }
        for (key, block) in previous where next[key] == nil {
            shrinkAway(block)
        }
        map.blocks = next
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    /// Lift, travel along a gentle arc, land with a small bounce.
    private func fly(_ block: BlockLayer, to target: CGRect, order: Int, delay: CFTimeInterval) {
        let start = block.presentation()?.frame ?? block.frame
        block.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block.frame = target
        block.style()
        CATransaction.commit()
        guard !reduceMotion else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = 0.15
            block.add(fade, forKey: "fade")
            return
        }
        let now = block.convertTime(CACurrentMediaTime(), from: nil)
        let begin = now + delay
        let ease = CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.15, 1.0)
        let from = CGPoint(x: start.midX, y: start.midY)
        let to = CGPoint(x: target.midX, y: target.midY)
        let dx = to.x - from.x, dy = to.y - from.y
        let distance = hypot(dx, dy)
        let side: CGFloat = order % 2 == 0 ? 1 : -1
        let control = CGPoint(x: (from.x + to.x) / 2 - dy / max(distance, 1) * distance * 0.18 * side,
                              y: (from.y + to.y) / 2 + dx / max(distance, 1) * distance * 0.18 * side)
        let path = CGMutablePath()
        path.move(to: from)
        path.addQuadCurve(to: to, control: control)
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.path = path
        travel.duration = Self.flight
        travel.timingFunction = ease
        travel.beginTime = begin
        travel.fillMode = .backwards
        block.add(travel, forKey: "position")
        let resize = CABasicAnimation(keyPath: "bounds.size")
        resize.fromValue = NSValue(size: start.size)
        resize.toValue = NSValue(size: target.size)
        resize.duration = Self.flight
        resize.timingFunction = ease
        resize.beginTime = begin
        resize.fillMode = .backwards
        block.add(resize, forKey: "bounds.size")
        guard distance > 2 || abs(start.width - target.width) > 2 else { return }
        let lift = CAKeyframeAnimation(keyPath: "transform.scale")
        lift.values = [1, 1.06, 0.98, 1]
        lift.keyTimes = [0, 0.4, 0.85, 1]
        lift.duration = Self.flight + 0.1
        lift.beginTime = begin
        block.add(lift, forKey: "lift")
    }

    private func shrinkAway(_ block: BlockLayer) {
        let start = block.presentation()?.frame ?? block.frame
        block.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setCompletionBlock { block.removeFromSuperlayer() }
        let shrink = CABasicAnimation(keyPath: "bounds.size")
        shrink.fromValue = NSValue(size: start.size)
        shrink.toValue = NSValue(size: .zero)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [shrink, fade]
        group.duration = reduceMotion ? 0.1 : 0.25
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        block.opacity = 0
        block.add(group, forKey: "shrink")
        CATransaction.commit()
    }

    // MARK: - Hiding

    private func dismiss(after delay: TimeInterval, fade duration: TimeInterval) {
        hideTask?.cancel()
        guard let map else { return }
        self.map = nil
        isVisible = false
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                map.panel.animator().alphaValue = 0
            }, completionHandler: nil)
            try? await Task.sleep(for: .seconds(duration))
            map.panel.orderOut(nil)
        }
    }
}

// MARK: - Layers

/// One slot as a block of glass: accent with a glow for main, teal for awareness, clear white for the rest, a bright
/// highlight along the top edge.
private final class BlockLayer: CAGradientLayer {
    var role: ArrangementPreview.Role

    init(role: ArrangementPreview.Role) {
        self.role = role
        super.init()
        cornerRadius = 7
        borderWidth = 1
        shadowOffset = CGSize(width: 0, height: -2)
        style()
    }

    override init(layer: Any) {
        role = (layer as? BlockLayer)?.role ?? .tile
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func style() {
        let color: NSColor = switch role {
        case .main: .controlAccentColor
        case .awareness: .systemTeal
        case .tile: .white
        }
        let strength: CGFloat = role == .tile ? 0.22 : 0.55
        colors = [color.withAlphaComponent(strength + 0.15).cgColor, color.withAlphaComponent(strength).cgColor]
        borderColor = color.withAlphaComponent(role == .tile ? 0.55 : 0.95).cgColor
        borderWidth = role == .main ? 1.5 : 1
        shadowColor = (role == .main ? NSColor.controlAccentColor : NSColor.black).cgColor
        shadowOpacity = role == .main ? 0.9 : 0.3
        shadowRadius = role == .main ? 10 : 4
    }
}

/// A band of slowly turning color around the map's edge, sharp inside and blurred outside: the model is still deciding.
private final class GlowLayer: CALayer {
    private var active = false

    func configure(size: CGSize, cornerRadius: CGFloat) {
        opacity = 0
        for (width, blur) in [(CGFloat(10), CGFloat(6)), (CGFloat(2.5), CGFloat(0))] {
            let container = CALayer()
            container.frame = CGRect(origin: .zero, size: size)
            let ring = CAShapeLayer()
            ring.frame = container.bounds
            ring.path = CGPath(roundedRect: container.bounds.insetBy(dx: width / 2, dy: width / 2), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ring.fillColor = nil
            ring.strokeColor = NSColor.white.cgColor
            ring.lineWidth = width
            container.mask = ring
            let side = hypot(size.width, size.height)
            let gradient = CAGradientLayer()
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.colors = [NSColor.systemPurple, .systemBlue, .systemTeal, .systemGreen, .systemYellow, .systemOrange, .systemPink, .systemPurple].map(\.cgColor)
            gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            gradient.position = CGPoint(x: size.width / 2, y: size.height / 2)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 2.5
            spin.repeatCount = .infinity
            gradient.add(spin, forKey: "spin")
            container.addSublayer(gradient)
            if blur > 0, let filter = CIFilter(name: "CIGaussianBlur") {
                filter.setValue(blur, forKey: kCIInputRadiusKey)
                container.filters = [filter]
                container.opacity = 0.8
            }
            addSublayer(container)
        }
    }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = presentation()?.opacity ?? opacity
        fade.toValue = on ? 1 : 0
        fade.duration = on ? 0.3 : 0.2
        opacity = on ? 1 : 0
        add(fade, forKey: "fade")
    }
}

/// The bottom row: the template's name, dots for where it is in the cycle, a spinner and a word while ranking.
private final class CaptionLayer: CALayer {
    private let text = CATextLayer()
    private let dots = CALayer()
    private let spinner = CAShapeLayer()

    func configure(scale: CGFloat) {
        text.contentsScale = scale
        text.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        text.fontSize = 13
        text.alignmentMode = .center
        text.foregroundColor = NSColor.white.cgColor
        text.shadowColor = NSColor.black.cgColor
        text.shadowOpacity = 0.5
        text.shadowRadius = 2
        text.shadowOffset = .zero
        addSublayer(text)
        addSublayer(dots)
        spinner.fillColor = nil
        spinner.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        spinner.lineWidth = 2
        spinner.lineCap = .round
        spinner.strokeEnd = 0.72
        spinner.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 12, height: 12), transform: nil)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 0.8
        spin.repeatCount = .infinity
        spinner.add(spin, forKey: "spin")
        addSublayer(spinner)
    }

    func show(_ caption: ArrangementPreview.Caption, waiting: Bool, width: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let label = waiting ? "\(caption.text)  ·  \(L("ranking…", "判断中…"))" : caption.text
        text.string = label
        text.frame = CGRect(x: 10, y: 18, width: width - 20, height: 18)
        let textWidth = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
        spinner.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        spinner.position = CGPoint(x: width / 2 - textWidth / 2 - 14, y: 27)
        spinner.opacity = waiting ? 1 : 0
        dots.sublayers?.forEach { $0.removeFromSuperlayer() }
        let dotSize: CGFloat = 6
        let total = CGFloat(caption.count) * (dotSize + 7) - 7
        for index in 0..<caption.count {
            let dot = CALayer()
            dot.frame = CGRect(x: (width - total) / 2 + CGFloat(index) * (dotSize + 7), y: 5, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dot.backgroundColor = (index == caption.index ? NSColor.white : NSColor.white.withAlphaComponent(0.3)).cgColor
            dots.addSublayer(dot)
        }
        CATransaction.commit()
    }
}
