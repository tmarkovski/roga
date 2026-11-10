import AppKit
import QuartzCore
import SwiftUI

/// What marks a command that one of your own agents carries out, and the thing
/// an agent is working on (decision 68): a thin orange line that stands still,
/// and a light that runs along it once when the pointer arrives and for as long
/// as the agent works.
struct AgentOutline: NSViewRepresentable {
    var shape = AgentOutlineView.Shape.outline(cornerRadius: 7)
    /// Whether the still line shows. Something an agent is working on keeps its
    /// own border, and only the light goes around it.
    var showsLine = true
    var isEnabled = true
    /// Whether the pointer is over it, which sends the light around once.
    var isHovering = false
    /// Whether the line is as bright as it is under the pointer without the
    /// pointer being there, as while a button's popover is open.
    var isLit = false
    /// Whether an agent is at work, which keeps the light going.
    var isWorking = false

    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    func makeNSView(context: Context) -> AgentOutlineView {
        AgentOutlineView()
    }

    func updateNSView(_ view: AgentOutlineView, context: Context) {
        view.shape = shape
        view.showsLine = showsLine
        view.isEnabled = isEnabled
        view.reducesMotion = reducesMotion
        view.isLit = isLit
        view.isWorking = isWorking
        // Last, since arriving is what sends the light, and it depends on the rest.
        view.isHovering = isHovering
    }
}

/// `AgentOutline`, in layers. Like `AgentRingView`, it leaves the moving to Core
/// Animation, which the render server plays, so neither SwiftUI nor Roga's main
/// thread does anything for each frame. Nothing moves at rest, and it stops when
/// its window can't be seen. For someone who asked for less motion, the line
/// brightens and stays still.
final class AgentOutlineView: NSView {
    enum Shape: Equatable {
        /// All the way around a rounded rectangle.
        case outline(cornerRadius: CGFloat)
        /// Along the top, from one side to the other and off the end, for something
        /// that runs edge to edge such as a dialog's command block.
        case topEdge
    }

    /// How far the light has to go and how much of its route it takes up, in
    /// shares of the path it's drawn along.
    struct Route: Equatable {
        /// How long the light is, from the far end of its tail to its front.
        var trail: CGFloat
        /// How much of the path one trip covers.
        var distance: CGFloat
        /// How long one trip takes while an agent works.
        var period: CFTimeInterval
    }

    /// One of the strokes the light is stacked from. They all end at the front
    /// of the light and each starts a little further forward than the one under
    /// it, so the light gets brighter by small steps instead of changing at one
    /// place, which a single stroke can't do because it has one color.
    struct Band: Equatable {
        /// Where along the light it starts, from 0 at the far end of the tail to
        /// 1 at the front.
        var start: CGFloat
        var opacity: CGFloat
        /// How far its color has gone from the brand's orange to the front's.
        var warmth: CGFloat
    }

    private static let bandCount = 16
    /// Above 1, the tail stays faint for longer and most of the light gathers
    /// near the front.
    private static let fadeCurve: CGFloat = 1.5
    /// Wider than the still line. Every band has this width, so the light looks
    /// thicker as it gets brighter, with no place where the width changes.
    private static let lightWidth: CGFloat = 1.5

    /// Each one adds the same step of brightness, so the bands are closer
    /// together where the light brightens fastest. An opacity of 1 / (bands left)
    /// is what makes those steps equal once they're stacked. The color arrives
    /// well before the last band, or that band would stand out as a block.
    static let bands: [Band] = (0..<bandCount).map { index in
        let count = CGFloat(bandCount)
        let reached = CGFloat(index + 1) / count
        return Band(
            start: pow(CGFloat(index) / count, 1 / fadeCurve),
            opacity: 1 / (count - CGFloat(index)),
            warmth: min(reached / 0.75, 1)
        )
    }

    var shape = Shape.outline(cornerRadius: 7) {
        didSet {
            guard shape != oldValue else { return }
            // The command block it runs along is dark in both appearances.
            appearance = shape == .topEdge ? NSAppearance(named: .darkAqua) : nil
            rebuild()
        }
    }
    var showsLine = true {
        didSet { if showsLine != oldValue { needsDisplay = true } }
    }
    var isEnabled = true {
        didSet { if isEnabled != oldValue { needsDisplay = true } }
    }
    var isLit = false {
        didSet { if isLit != oldValue { updateColors(animated: true) } }
    }
    var reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        didSet {
            guard reducesMotion != oldValue else { return }
            needsDisplay = true
            updateTravel()
        }
    }
    var isWorking = false {
        didSet {
            guard isWorking != oldValue else { return }
            updateColors(animated: true)
            updateTravel()
        }
    }
    var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            updateColors(animated: true)
            if isHovering { sendLightAround() }
        }
    }

    private let line = CAShapeLayer()
    private let lightBands = AgentOutlineView.bands.map { _ in CAShapeLayer() }
    private var route: Route?
    private var isLooping = false

    /// How long the light takes to go around once under the pointer.
    static let passDuration: CFTimeInterval = 1.15
    private static let travelKey = "travel"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [line] + lightBands {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            layer?.addSublayer(shape)
        }
        line.lineWidth = 1
        for shape in lightBands {
            shape.lineWidth = Self.lightWidth
            // The light is out of sight until an animation moves it.
            shape.strokeEnd = 0
        }
        // Only the front glows, because the render server draws a shadow again
        // for every frame.
        front.shadowOffset = .zero
        front.shadowRadius = 3.5
        front.shadowOpacity = 1
    }

    private var front: CAShapeLayer { lightBands[lightBands.count - 1] }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Top-down, like SwiftUI.
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// Clicks and hovering go to what it's drawn around.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Whether the light is moving right now, which tests read.
    var isTraveling: Bool {
        front.animation(forKey: Self.travelKey) != nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let drawn = Self.paths(for: shape, in: bounds)
        let route = Self.route(for: shape, size: bounds.size)
        let changed = route != self.route
        self.route = route
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.masksToBounds = shape == .topEdge
        for shape in [line] + lightBands {
            shape.frame = bounds
        }
        line.path = drawn.line
        for shape in lightBands {
            shape.path = drawn.route
        }
        CATransaction.commit()
        // Its shares of the path change with the size, so a trip under way has
        // to start again with the new ones.
        if changed, isLooping {
            removeTravel()
        }
        updateTravel()
    }

    /// The path of the still line, and the one the light goes along.
    static func paths(for shape: Shape, in bounds: CGRect) -> (line: CGPath?, route: CGPath) {
        switch shape {
        case .outline(let radius):
            // Inside the edge, so that a one-point line is on whole points.
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let outline = Path(roundedRect: rect, cornerRadius: max(radius - 0.5, 0), style: .continuous).cgPath
            // Going around twice lets a stretch of the path wrap past where the
            // path starts, which a single loop's start and end can't do.
            let twice = CGMutablePath()
            twice.addPath(outline)
            twice.addPath(outline)
            return (outline, twice)
        case .topEdge:
            // From past the left side to past the right, so that it comes in
            // and goes out at the edges.
            let reach = trailLength(forTopEdgeOf: bounds.width)
            let along = CGMutablePath()
            along.move(to: CGPoint(x: bounds.minX - reach, y: bounds.minY + 0.75))
            along.addLine(to: CGPoint(x: bounds.maxX + reach, y: bounds.minY + 0.75))
            return (nil, along)
        }
    }

    /// The light is a share of something small, and stops growing so that a long
    /// way around doesn't get a light as long as a window.
    private static func trailLength(forTopEdgeOf width: CGFloat) -> CGFloat {
        min(width * 0.34, 190)
    }

    static func route(for shape: Shape, size: CGSize) -> Route {
        switch shape {
        case .outline(let radius):
            let perimeter = 2 * (size.width + size.height) - 8 * radius + 2 * .pi * radius
            let trail = min(perimeter * 0.32, 210)
            // Slower around something bigger, so that it doesn't race.
            let period = min(max(perimeter / 450, 1.7), 4)
            return Route(trail: trail / (2 * perimeter), distance: 0.5, period: period)
        case .topEdge:
            let trail = trailLength(forTopEdgeOf: size.width)
            let path = size.width + 2 * trail
            return Route(trail: trail / path, distance: 1 - trail / path, period: 1.7)
        }
    }

    /// One band's trip along the route, or one after another for as long as `looping`.
    /// A loop starts as far into a trip as the clock is, which keeps outlines of
    /// the same size in step when several show.
    static func trip(
        of band: Band, on route: Route, looping: Bool, now: CFTimeInterval
    ) -> CAAnimationGroup {
        let duration = looping ? route.period : passDuration
        let from = route.trail * band.start
        let start = CABasicAnimation(keyPath: "strokeStart")
        start.fromValue = from
        start.toValue = from + route.distance
        start.duration = duration
        let end = CABasicAnimation(keyPath: "strokeEnd")
        end.fromValue = route.trail
        end.toValue = route.trail + route.distance
        end.duration = duration
        let group = CAAnimationGroup()
        group.duration = duration
        if looping {
            group.animations = [start, end]
            group.timingFunction = CAMediaTimingFunction(name: .linear)
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            group.timeOffset = now.truncatingRemainder(dividingBy: duration)
        } else {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.12, 0.85, 1]
            fade.duration = duration
            group.animations = [start, end, fade]
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.05, 0.4, 0.95)
        }
        return group
    }

    private var canBeSeen: Bool {
        window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
    }

    private func addTravel(looping: Bool) {
        guard let route else { return }
        let now = CACurrentMediaTime()
        for (shape, band) in zip(lightBands, Self.bands) {
            shape.add(Self.trip(of: band, on: route, looping: looping, now: now), forKey: Self.travelKey)
        }
    }

    private func removeTravel() {
        for shape in lightBands {
            shape.removeAnimation(forKey: Self.travelKey)
        }
        isLooping = false
    }

    /// Starts the light going while an agent works and someone can see it, and
    /// stops it otherwise, so that the render server has nothing to play for a
    /// window nobody sees.
    private func updateTravel() {
        if isWorking, !reducesMotion, canBeSeen, route != nil {
            guard !isLooping else { return }
            isLooping = true
            addTravel(looping: true)
        } else if isLooping {
            removeTravel()
        }
    }

    private func sendLightAround() {
        guard isEnabled, !isWorking, !reducesMotion, canBeSeen else { return }
        addTravel(looping: false)
    }

    override func updateLayer() {
        updateColors(animated: false)
    }

    private func updateColors(animated: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            if animated {
                CATransaction.setAnimationDuration(0.15)
            } else {
                CATransaction.setDisableActions(true)
            }
            let isBright = isEnabled && (isHovering || isLit || isWorking)
            let color = !isEnabled ? Palette.separator : isBright ? AgentColors.outlineLit : AgentColors.outline
            line.strokeColor = NSColor(color).cgColor
            // Someone who asked for less motion gets a brighter line for the
            // light that would have gone around it.
            line.isHidden = !showsLine && !(isWorking && reducesMotion)
            for (shape, band) in zip(lightBands, Self.bands) {
                shape.strokeColor = Self.color(of: band)
            }
            front.shadowColor = NSColor(AgentColors.glow).cgColor
            CATransaction.commit()
        }
    }

    /// For the current drawing appearance.
    private static func color(of band: Band) -> CGColor {
        let orange = NSColor(AgentColors.outlineLit).usingColorSpace(.sRGB)?.withAlphaComponent(1)
        let light = NSColor(AgentColors.light).usingColorSpace(.sRGB) ?? NSColor(AgentColors.light)
        let mixed = orange?.blended(withFraction: band.warmth, of: light) ?? light
        return mixed.withAlphaComponent(band.opacity).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateTravel()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateTravel()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
        }
        // Core Animation drops a layer's animations when it leaves a window.
        isLooping = isLooping && isTraveling
        updateTravel()
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        updateTravel()
    }
}

extension AgentOutlineView {
    /// One that goes around what an agent is working on, with the light going and
    /// no line of its own, for places outside SwiftUI.
    static func aroundWork(cornerRadius: CGFloat) -> AgentOutlineView {
        let view = AgentOutlineView()
        view.shape = .outline(cornerRadius: cornerRadius)
        view.showsLine = false
        view.isWorking = true
        return view
    }
}
