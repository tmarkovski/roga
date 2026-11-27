import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import RogaUI

/// The window animations in layers, which mark an agent at work: they draw
/// what the canvas draws, play only while someone can see them, play in step,
/// and each launch of Roga picks a different one.
@MainActor
struct HouseWindowLayerViewTests {
    private static let side: CGFloat = 112

    /// A view drawn in a window that's never shown, the way the sidebar hosts
    /// the marks. `ImageRenderer` can't draw an `NSView`, so the canvas is
    /// drawn the same way, which also puts both through the same colors.
    private static func image(of view: NSView, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: side, height: side), styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }

    private static func layers(
        _ animation: HouseWindowAnimation, rotation: Angle, appearance: NSAppearance.Name
    ) throws -> NSBitmapImageRep {
        let view = HouseWindowLayerView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        view.animation = animation
        view.rotation = rotation
        return try image(of: view, appearance: appearance)
    }

    /// The canvas's drawing of the same still frame.
    private static func canvas(
        _ animation: HouseWindowAnimation, rotation: Angle, appearance: NSAppearance.Name
    ) throws -> NSBitmapImageRep {
        let figure = HouseWindowFigure(animation: animation, time: animation.stillTime, rotation: rotation)
            .frame(width: side, height: side)
        return try image(of: NSHostingView(rootView: figure), appearance: appearance)
    }

    /// How far apart two pixels are, in the most different of their channels,
    /// with the color weighed by how much of the pixel it covers.
    private static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let a = a.usingColorSpace(.sRGB) ?? .clear
        let b = b.usingColorSpace(.sRGB) ?? .clear
        return max(
            abs(a.redComponent * a.alphaComponent - b.redComponent * b.alphaComponent),
            abs(a.greenComponent * a.alphaComponent - b.greenComponent * b.alphaComponent),
            abs(a.blueComponent * a.alphaComponent - b.blueComponent * b.alphaComponent),
            abs(a.alphaComponent - b.alphaComponent)
        )
    }

    /// Every animation's still frame, at the logo's tilt and upright, as an
    /// agent's mark draws it, and in both appearances, looks the same in layers
    /// as on the canvas, apart from how the edges are smoothed.
    @Test(arguments: HouseWindowAnimation.allCases, [HouseWindowAnimation.logoRotation, .zero])
    func theLayersDrawWhatTheCanvasDraws(_ animation: HouseWindowAnimation, rotation: Angle) throws {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let layers = try Self.layers(animation, rotation: rotation, appearance: appearance)
            let canvas = try Self.canvas(animation, rotation: rotation, appearance: appearance)
            #expect(canvas.pixelsWide == layers.pixelsWide && canvas.pixelsHigh == layers.pixelsHigh)
            var inked = 0
            var different = 0
            for y in 0..<layers.pixelsHigh {
                for x in 0..<layers.pixelsWide {
                    let drawn = try #require(layers.colorAt(x: x, y: y))
                    let expected = try #require(canvas.colorAt(x: x, y: y))
                    if drawn.alphaComponent > 0.05 || expected.alphaComponent > 0.05 { inked += 1 }
                    if Self.distance(drawn, expected) > 0.12 { different += 1 }
                }
            }
            #expect(inked > 1000, "\(animation) at \(rotation.degrees)° drew nothing in \(appearance.rawValue)")
            #expect(Double(different) < 0.01 * Double(inked), "\(animation) at \(rotation.degrees)° in \(appearance.rawValue): \(different) of \(inked) pixels differ")
        }
    }

    /// What Core Animation plays is the canvas's animation: at moments all
    /// through a loop, the panes are where the canvas puts them, in its colors
    /// and with its glow, and the band of light is where the canvas draws it.
    /// Between the poses sampled 60 times a second it goes in straight lines,
    /// which is a little off where the canvas turns sharply.
    @Test(arguments: HouseWindowAnimation.allCases)
    func theLoopsPlayTheCanvasesPoses(_ animation: HouseWindowAnimation) throws {
        let size = CGSize(width: Self.side, height: Self.side)
        // Upright, as an agent's mark draws them.
        let rotation = Angle.zero
        let view = HouseWindowLayerView(frame: CGRect(origin: .zero, size: size))
        view.animation = animation
        view.rotation = rotation
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        // The panes, then the band of light, as the view adds them.
        let layers = try #require(view.layer?.sublayers)
        let panes = layers.prefix(4).compactMap { $0 as? CAShapeLayer }
        let beam = try #require(layers.last as? CAGradientLayer)
        #expect(panes.count == 4)

        let placement = HouseWindowFigure.placement(in: size, rotation: rotation)
        let colors = HouseWindowColors(dark: false)
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        func components(_ color: CGColor) throws -> [CGFloat] {
            try #require(color.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components)
        }
        // The view's clock stands still, at whatever moment it's set to, so
        // that what's read is exactly that moment.
        let clock = try #require(view.layer)
        clock.speed = 0
        for (layer, loop) in zip(layers, HouseWindowLayerView.loops(for: animation, rotation: rotation, size: size, isDark: false, at: 0)) {
            guard let loop else { continue }
            loop.beginTime = 1
            layer.add(loop, forKey: HouseWindowLayerView.playKey)
        }
        for step in 0..<24 {
            let time = animation.duration * Double(step) / 24 + 0.011
            clock.timeOffset = 1 + time
            CATransaction.flush()

            for (pane, layer) in zip(HouseOutline.Pane.allCases, panes) {
                let shown = try #require(layer.presentation())
                let pose = animation.pose(of: pane, at: time)
                let bounds = pane.path.boundingRect
                let expected = placement.inverted()
                    .concatenating(pose.transform(around: CGPoint(x: bounds.midX, y: bounds.midY)))
                    .concatenating(placement)
                let move = CATransform3DGetAffineTransform(shown.transform)
                let moveError = max(
                    abs(move.a - expected.a), abs(move.b - expected.b), abs(move.c - expected.c), abs(move.d - expected.d),
                    abs(move.tx - expected.tx) / Self.side, abs(move.ty - expected.ty) / Self.side
                )
                #expect(moveError < 0.01, "\(animation) \(pane) at \(time): moved \(move), not \(expected)")

                let fill = try components(try #require(shown.fillColor))
                let wanted = try components(colors.fill(warmth: pose.warmth).resolve(in: EnvironmentValues()).cgColor)
                #expect(zip(fill, wanted).allSatisfy { abs($0 - $1) < 0.02 }, "\(animation) \(pane) at \(time): \(fill), not \(wanted)")

                let glow = pose.glow * Self.side / HouseWindowFigure.frame.width
                #expect(abs(Double(shown.shadowRadius) - glow) < 0.05, "\(animation) \(pane) at \(time): glow \(shown.shadowRadius), not \(glow)")
                // As a glow starts, its strength turns sharply between two
                // poses, while it's too narrow to see.
                if glow > 0.5 {
                    #expect(abs(Double(shown.shadowOpacity) - min(pose.glow, 1)) < 0.02, "\(animation) \(pane) at \(time): glow opacity \(shown.shadowOpacity)")
                }
            }

            let line = HouseWindowFigure.beam(of: animation, at: time)
            #expect(beam.isHidden == (line == nil))
            if let line {
                let shown = try #require(beam.presentation())
                let start = line.start.applying(placement)
                let end = line.end.applying(placement)
                #expect(abs(shown.startPoint.x - start.x / Self.side) < 0.01 && abs(shown.startPoint.y - start.y / Self.side) < 0.01)
                #expect(abs(shown.endPoint.x - end.x / Self.side) < 0.01 && abs(shown.endPoint.y - end.y / Self.side) < 0.01)
            }
        }
    }

    /// Nothing plays where nobody can see it: out of a window, or in one that
    /// isn't on screen. A test can't put a window on someone's screen, so the
    /// test copy checked that it plays while it can be seen.
    @Test func itPlaysOnlyWhileItCanBeSeen() {
        let view = HouseWindowLayerView(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        view.plays = true
        #expect(!view.isPlaying)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 18, height: 18), styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        #expect(!window.occlusionState.contains(.visible))
        #expect(!view.isPlaying)
    }

    /// Each loop goes on forever and starts as far into a loop as the clock
    /// is, so that marks started at different moments show the same pose at
    /// the same moment.
    @Test func marksPlayInStep() throws {
        let track = CAKeyframeAnimation(keyPath: "fillColor")
        let first = try #require(HouseWindowLayerView.loop([track], duration: 2.2, at: 1000.5))
        let later = try #require(HouseWindowLayerView.loop([track], duration: 2.2, at: 1000.5 + 3 * 2.2))
        #expect(first.duration == 2.2 && first.repeatCount == .infinity)
        #expect(track.duration == 2.2)
        #expect(abs(first.timeOffset - 1000.5.truncatingRemainder(dividingBy: 2.2)) < 1e-9)
        #expect(abs(later.timeOffset - first.timeOffset) < 1e-6)
        #expect(HouseWindowLayerView.loop([], duration: 2.2, at: 1000) == nil)
    }

    /// Each launch picks any animation but the one the last launch showed,
    /// and keeps its pick for the next launch to avoid.
    @Test func eachLaunchPicksADifferentAnimation() throws {
        let suite = "HouseWindowLayerViewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var last = HouseWindowAnimation.pickForLaunch(in: defaults)
        var seen: Set<HouseWindowAnimation> = [last]
        for _ in 0..<200 {
            let picked = HouseWindowAnimation.pickForLaunch(in: defaults)
            #expect(picked != last)
            #expect(defaults.string(forKey: HouseWindowAnimation.lastLaunchKey) == picked.rawValue)
            seen.insert(picked)
            last = picked
        }
        #expect(seen == Set(HouseWindowAnimation.allCases))
    }

    /// A stored name that isn't an animation, say from a later version that
    /// added one, doesn't keep a launch from picking.
    @Test func aNameItDoesntKnowLeavesEveryAnimationToPick() throws {
        let suite = "HouseWindowLayerViewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("somethingNew", forKey: HouseWindowAnimation.lastLaunchKey)

        var generator = SystemRandomNumberGenerator()
        var seen: Set<HouseWindowAnimation> = []
        for _ in 0..<200 {
            seen.insert(HouseWindowAnimation.pick(after: nil, using: &generator))
        }
        #expect(seen == Set(HouseWindowAnimation.allCases))
        #expect(HouseWindowAnimation.allCases.contains(HouseWindowAnimation.pickForLaunch(in: defaults)))
    }
}
