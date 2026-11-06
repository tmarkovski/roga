import AppKit
import IconUI
import QuartzCore
import SwiftUI

/// The mark a sidebar row shows for an agent (decision 41): a turning ring
/// while it works, the amber circle-alert while it waits for you, and a blue
/// dot once it has finished and nobody has looked yet.
///
/// The ring is the design canvas's: a gray track with a quarter of it in the
/// brand's orange, from the top. The quarter turns once a second, so that it
/// doesn't read as progress stuck at a quarter. Core Animation turns it rather
/// than SwiftUI, because a repeating SwiftUI animation would redraw the sidebar
/// many times a second for as long as an agent works, which can be hours (see
/// `AgentRingView`). The waiting mark is a circle rather than the canvas's
/// triangle, since decision 28's red triangle already means conflicts.
/// VoiceOver doesn't read the mark, because the row describes it.
struct AgentMark: View {
    let state: AgentSummary.State
    /// The width and height it takes up. The canvas draws marks in a 16-point
    /// box at 14 points.
    var size: CGFloat = 14

    /// The ring stands still for someone who asked for less motion, as the
    /// house does.
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    /// How much of the icon's width the waiting mark's font size is. Roga's
    /// icons are as wide as their 24-point grid, which comes to 1.128 times
    /// the font's size.
    private static let iconWidthPerPoint: CGFloat = 1.128
    /// How much smaller than its box the circle-alert is drawn. At full size
    /// it would fill the box, while the ring's outer edge is 13/16 of it. At
    /// this size both measure about 0.81 of the box, so the two look as big
    /// as each other in the sidebar and in the legends in Settings alike.
    private static let waitingScale: CGFloat = 0.88

    var body: some View {
        Group {
            switch state {
            case .working:
                AgentRing(spins: !reducesMotion)
            case .waiting:
                Icon.circleAlert.image
                    .font(.system(size: size * Self.waitingScale / Self.iconWidthPerPoint, weight: .medium))
                    .foregroundStyle(AgentColors.warn)
            case .finished:
                Circle()
                    .fill(AgentColors.finished)
                    .frame(width: size / 2, height: size / 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The working ring, drawn by `AgentRingView` at whatever size it's given.
private struct AgentRing: NSViewRepresentable {
    let spins: Bool

    func makeNSView(context: Context) -> AgentRingView {
        AgentRingView()
    }

    func updateNSView(_ view: AgentRingView, context: Context) {
        view.spins = spins
    }
}

/// The canvas's ring, in layers: a circle of radius 5.5 in a 16-point box,
/// stroked 2 points wide, and a quarter arc from the top with round ends,
/// scaled to the view's width. While `spins` is set, the arc turns clockwise
/// once a second.
///
/// The turning is a `CABasicAnimation` that repeats forever, which the render
/// server plays, so neither SwiftUI nor Roga's main thread does anything for
/// each frame. It stops whenever the window can't be seen, being minimized,
/// hidden, on another Space or fully covered, and starts again when it can.
/// Every ring turns in step with the others, whenever each started, so that a
/// sidebar of agents at work looks calm rather than busy.
final class AgentRingView: NSView {
    /// Whether the arc turns while the window can be seen.
    var spins = false {
        didSet {
            if spins != oldValue { updateSpinning() }
        }
    }

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    /// How long the arc takes to go around once.
    static let turn: CFTimeInterval = 1
    static let spinKey = "spin"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Top-down, like SwiftUI, so that the arc starts at the top.
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// Clicks and hovering go to the row the ring is in.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Whether the arc is turning right now, which tests read.
    var isTurning: Bool {
        arc.animation(forKey: Self.spinKey) != nil
    }

    override func layout() {
        super.layout()
        let scale = bounds.width / 16
        let radius = 5.5 * scale
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let circle = CGPath(
            ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius),
            transform: nil
        )
        let quarter = CGMutablePath()
        // In a top-down view, angles grow clockwise, and -π/2 is the top.
        quarter.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, arc] {
            // The arc turns about its middle, which is the view's.
            shape.frame = bounds
            shape.lineWidth = 2 * scale
        }
        track.path = circle
        arc.path = quarter
        CATransaction.commit()
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.strokeColor = NSColor(AgentColors.ringTrack).cgColor
            arc.strokeColor = NSColor(Palette.action).cgColor
            CATransaction.commit()
        }
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
        updateSpinning()
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        updateSpinning()
    }

    /// Starts the arc turning, or stops it, for whether it should spin and
    /// whether anyone can see it. Stopping takes the animation away, so that
    /// the render server has nothing to play for a window nobody sees.
    func updateSpinning() {
        if spins, let window, window.occlusionState.contains(.visible) {
            guard arc.animation(forKey: Self.spinKey) == nil else { return }
            arc.add(Self.spin(at: CACurrentMediaTime()), forKey: Self.spinKey)
        } else {
            arc.removeAnimation(forKey: Self.spinKey)
        }
    }

    /// One turn after another, clockwise in a top-down view, for an arc that
    /// starts turning at `now` on Core Animation's clock. It starts partway
    /// through a turn, as far as the clock is into one, which puts every ring
    /// at the same angle at the same moment.
    static func spin(at now: CFTimeInterval) -> CABasicAnimation {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = turn
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        spin.timeOffset = now.truncatingRemainder(dividingBy: turn)
        return spin
    }
}

/// The colors of agents' marks and of what Settings says about agents, from
/// the design canvas's Settings boards.
enum AgentColors {
    /// Amber, for an agent that waits for you, and for a warning that isn't an
    /// error.
    static let warn = DialogColors.appearanceColor(light: 0x9A5200, dark: 0xF0A54A)
    /// Green, for what works, such as hooks that are installed.
    static let ok = DialogColors.appearanceColor(light: 0x3F7D00, dark: 0xA6E22E)
    /// The blue of a dot for what finished and nobody has looked at yet, the
    /// same in both appearances.
    static let finished = DialogColors.appearanceColor(light: 0x2F6DE1, dark: 0x2F6DE1)
    /// The track of the ring, in the canvas's line gray.
    static let ringTrack = SettingsColors.line
}
