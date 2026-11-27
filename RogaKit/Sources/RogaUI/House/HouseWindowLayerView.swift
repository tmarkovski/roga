import AppKit
import QuartzCore
import SwiftUI

/// A window animation in layers, for a mark that can play for hours, such as
/// an agent's while it works (decision 122). `HouseWindowAnimationView` works
/// out each frame in SwiftUI on Roga's main thread, which is fine for a few
/// seconds and too much for a sidebar of agents at work. Here each pane is a
/// shape layer, and Core Animation plays the poses in the render server, as
/// it turned the ring before (decision 46), so neither SwiftUI nor the main
/// thread does anything for each frame.
///
/// The poses are the animation's own, sampled 60 times a second over one loop,
/// and Core Animation draws straight lines between them. The view's bounds
/// are the animation's drawing area, as `HouseWindowAnimationView`'s size is,
/// and `rotation` tilts the whole animation as that view's does.
///
/// It plays only while its window can be seen, and every one plays in step
/// with the others, whenever each started, so that a sidebar of agents at work
/// looks calm rather than busy. While it isn't playing, it shows the
/// animation's still frame, the one Reduce Motion shows.
final class HouseWindowLayerView: NSView {
    var animation = HouseWindowAnimation.windowChase {
        didSet {
            if animation != oldValue { rebuild() }
        }
    }

    /// The overall clockwise tilt, as in `HouseWindowAnimationView`. Zero is
    /// an upright window.
    var rotation = HouseWindowAnimation.logoRotation {
        didSet {
            if rotation != oldValue { rebuild() }
        }
    }

    /// Whether it plays while the window can be seen.
    var plays = false {
        didSet {
            if plays != oldValue { updatePlaying() }
        }
    }

    private let panes = HouseOutline.Pane.allCases.map { _ in CAShapeLayer() }
    private let beam = CAGradientLayer()
    private let beamMask = CAShapeLayer()
    /// What the layers were last built for, so that they're built again only
    /// when one of these changes.
    private var built: Keyframes.Key?

    static let playKey = "play"
    /// How many poses a second of the animation is sampled at.
    static let framesPerSecond = 60.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for pane in panes {
            // Each pane's transform moves it about the view's corner, which
            // is where its coordinates start.
            pane.anchorPoint = .zero
            pane.shadowOffset = .zero
            pane.shadowOpacity = 0
            layer?.addSublayer(pane)
        }
        beam.mask = beamMask
        layer?.addSublayer(beam)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Top-down, like SwiftUI, so that the poses move the panes as the canvas
    /// moves them.
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// Clicks and hovering go to the row the mark is in.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Whether the animation is playing right now, which tests read.
    var isPlaying: Bool {
        layers.contains { $0.animation(forKey: Self.playKey) != nil }
    }

    private var layers: [CALayer] {
        [beam] + (panes as [CALayer])
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    override func updateLayer() {
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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
        updatePlaying()
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        updatePlaying()
    }

    /// Builds the layers again for the view's size, its appearance and the
    /// animation, if any of them changed, and carries on playing.
    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let key = Keyframes.Key(
            animation: animation, rotation: rotation.degrees, width: bounds.width, height: bounds.height, isDark: isDark
        )
        guard key != built else { return }
        built = key
        let keyframes = Keyframes.for(key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (pane, path) in zip(panes, keyframes.paths) {
            pane.bounds = bounds
            pane.position = .zero
            pane.path = path
            pane.shadowPath = path
            pane.shadowColor = keyframes.halo
        }
        beam.frame = bounds
        beamMask.frame = beam.bounds
        beamMask.path = keyframes.window
        beam.colors = keyframes.beamColors
        beam.locations = keyframes.beamLocations
        beam.isHidden = keyframes.still.beam == nil
        show(keyframes.still)
        CATransaction.commit()
        for layer in layers {
            layer.removeAnimation(forKey: Self.playKey)
        }
        updatePlaying()
    }

    /// Puts the layers in one pose, which is what they show while the
    /// animation isn't playing.
    private func show(_ frame: Keyframes.Frame) {
        for (layer, pane) in zip(panes, frame.panes) {
            layer.transform = pane.transform
            layer.fillColor = pane.fill
            layer.shadowRadius = pane.glowRadius
            layer.shadowOpacity = pane.glowOpacity
        }
        if let line = frame.beam {
            beam.startPoint = line.start
            beam.endPoint = line.end
        }
    }

    /// Starts the animation playing, or stops it, for whether it should play
    /// and whether anyone can see it. Stopping takes the animations away, so
    /// that the render server has nothing to play for a window nobody sees.
    func updatePlaying() {
        guard let built else { return }
        if plays, let window, window.occlusionState.contains(.visible) {
            guard !isPlaying else { return }
            let loops = Self.loops(for: built, at: CACurrentMediaTime())
            for (layer, loop) in zip(panes as [CALayer] + [beam], loops) {
                if let loop { layer.add(loop, forKey: Self.playKey) }
            }
        } else {
            for layer in layers {
                layer.removeAnimation(forKey: Self.playKey)
            }
        }
    }

    /// What each pane plays, in the order of `HouseOutline.Pane.allCases`, and
    /// then the band of light, for an animation at a tilt and a size and in an
    /// appearance. Nil is for a layer that never changes.
    static func loops(
        for animation: HouseWindowAnimation, rotation: Angle, size: CGSize, isDark: Bool, at now: CFTimeInterval
    ) -> [CAAnimationGroup?] {
        let key = Keyframes.Key(animation: animation, rotation: rotation.degrees, width: size.width, height: size.height, isDark: isDark)
        return loops(for: key, at: now)
    }

    private static func loops(for key: Keyframes.Key, at now: CFTimeInterval) -> [CAAnimationGroup?] {
        let keyframes = Keyframes.for(key)
        let duration = key.animation.duration
        var loops = HouseOutline.Pane.allCases.indices.map { index in
            let poses = keyframes.loop.map { $0.panes[index] }
            return loop([
                track("transform", poses.map { NSValue(caTransform3D: $0.transform) }),
                track("fillColor", poses.map(\.fill)),
                track("shadowRadius", poses.map(\.glowRadius)),
                track("shadowOpacity", poses.map(\.glowOpacity)),
            ].compactMap(\.self), duration: duration, at: now)
        }
        let lines = keyframes.loop.compactMap(\.beam)
        loops.append(lines.count < keyframes.loop.count ? nil : loop([
            track("startPoint", lines.map { NSValue(point: $0.start) }),
            track("endPoint", lines.map { NSValue(point: $0.end) }),
        ].compactMap(\.self), duration: duration, at: now))
        return loops
    }

    /// One property's poses over a loop, evenly spaced, or nil when it never
    /// changes, which leaves the render server nothing to do for it.
    private static func track(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation? {
        guard let first = values.first.map({ $0 as AnyObject }),
              !values.dropFirst().allSatisfy({ ($0 as AnyObject).isEqual(first) })
        else { return nil }
        let track = CAKeyframeAnimation(keyPath: keyPath)
        track.values = values
        track.calculationMode = .linear
        return track
    }

    /// The tracks played together, one loop after another, for a layer that
    /// starts playing at `now` on Core Animation's clock. It starts as far
    /// into a loop as the clock is, which puts every mark at the same pose at
    /// the same moment.
    static func loop(_ tracks: [CAKeyframeAnimation], duration: CFTimeInterval, at now: CFTimeInterval) -> CAAnimationGroup? {
        guard !tracks.isEmpty else { return nil }
        for track in tracks {
            track.duration = duration
        }
        let loop = CAAnimationGroup()
        loop.animations = tracks
        loop.duration = duration
        loop.repeatCount = .infinity
        loop.isRemovedOnCompletion = false
        loop.timeOffset = now.truncatingRemainder(dividingBy: duration)
        return loop
    }
}

/// What the layers show over one loop of an animation, at one tilt and size and
/// in one appearance, which every view drawing the same thing shares.
private struct Keyframes {
    struct Key: Hashable {
        var animation: HouseWindowAnimation
        /// The tilt, in degrees.
        var rotation: Double
        var width: CGFloat
        var height: CGFloat
        var isDark: Bool

        var size: CGSize { CGSize(width: width, height: height) }
    }

    /// One pane in one pose, as the layer's properties take it.
    struct Pane {
        var transform: CATransform3D
        var fill: CGColor
        var glowRadius: CGFloat
        var glowOpacity: Float
    }

    /// Every pane in one pose, and the band of light, in the gradient's unit
    /// coordinates, for an animation that has one.
    struct Frame {
        var panes: [Pane]
        var beam: (start: CGPoint, end: CGPoint)?
    }

    /// Each pane at rest, placed in the view.
    let paths: [CGPath]
    /// All four panes at rest, which the band of light fills.
    let window: CGPath
    let halo: CGColor
    let beamColors: [CGColor]
    let beamLocations: [NSNumber]
    /// The still frame.
    let still: Frame
    /// The poses from the start of a loop to its end, which is the start again.
    let loop: [Frame]

    private static var cache: [Key: Keyframes] = [:]

    static func `for`(_ key: Key) -> Keyframes {
        if let keyframes = cache[key] { return keyframes }
        let keyframes = Keyframes(key)
        cache[key] = keyframes
        return keyframes
    }

    private init(_ key: Key) {
        let animation = key.animation
        let size = key.size
        let placement = HouseWindowFigure.placement(in: size, rotation: .degrees(key.rotation))
        let colors = HouseWindowColors(dark: key.isDark)
        paths = HouseOutline.Pane.allCases.map { $0.path.applying(placement).cgPath }
        window = HouseOutline.window.applying(placement).cgPath
        halo = Self.cgColor(colors.halo)
        let stops = colors.beam.stops
        beamColors = stops.map { Self.cgColor($0.color) }
        beamLocations = stops.map { NSNumber(value: Double($0.location)) }

        let frame = { (time: TimeInterval) in
            Self.frame(of: animation, at: time, placement: placement, size: size, colors: colors)
        }
        still = frame(animation.stillTime)
        let count = Int((animation.duration * HouseWindowLayerView.framesPerSecond).rounded(.up))
        loop = (0...count).map { frame(animation.duration * Double($0) / Double(count)) }
    }

    private static func frame(
        of animation: HouseWindowAnimation, at time: TimeInterval, placement: CGAffineTransform, size: CGSize, colors: HouseWindowColors
    ) -> Frame {
        let scale = min(size.width, size.height) / HouseWindowFigure.frame.width
        let unplaced = placement.inverted()
        let panes = HouseOutline.Pane.allCases.map { pane in
            let bounds = pane.path.boundingRect
            let pose = animation.pose(of: pane, at: time)
            // The pose moves the pane in the mark's coordinates, and the layer
            // holds it already placed in the view's.
            let move = unplaced
                .concatenating(pose.transform(around: CGPoint(x: bounds.midX, y: bounds.midY)))
                .concatenating(placement)
            return Pane(
                transform: CATransform3DMakeAffineTransform(move),
                fill: cgColor(colors.fill(warmth: pose.warmth)),
                glowRadius: pose.glow * scale,
                // The canvas adds no glow at all at 0, rather than one with no
                // blur, which would tint the pane's edge.
                glowOpacity: Float(min(pose.glow, 1))
            )
        }
        let beam = HouseWindowFigure.beam(of: animation, at: time).map { line in
            let unit = { (point: CGPoint) in
                let placed = point.applying(placement)
                return CGPoint(x: placed.x / size.width, y: placed.y / size.height)
            }
            return (start: unit(line.start), end: unit(line.end))
        }
        return Frame(panes: panes, beam: beam)
    }

    /// The color SwiftUI would draw, mixes included.
    private static func cgColor(_ color: Color) -> CGColor {
        color.resolve(in: EnvironmentValues()).cgColor
    }
}
