import AgentHooks
import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import RogaUI

/// The agents' marks: each takes the box it's given, the waiting circle looks
/// as big as the ring wherever a mark is drawn, and the ring turns only while
/// someone can see it.
struct AgentMarkTests {
    static let states: [AgentSummary.State] = [.working, .waiting(.question), .finished]

    /// A mark drawn in a window that's never shown, the way the sidebar hosts
    /// it. `ImageRenderer` can't draw the ring, which is an `NSView`.
    private static func image(
        _ state: AgentSummary.State, size: CGFloat, appearance: NSAppearance.Name = .aqua
    ) throws -> NSBitmapImageRep {
        try image(AgentMark(state: state, size: size), size: size, appearance: appearance)
    }

    private static func image(
        _ view: some View, size: CGFloat, appearance: NSAppearance.Name = .aqua
    ) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: size, height: size), styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        return image
    }

    /// The color of each pixel, top row first, in sRGB.
    private static func pixels(_ image: NSBitmapImageRep) -> [[NSColor]] {
        (0..<image.pixelsHigh).map { y in
            (0..<image.pixelsWide).map { x in
                image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
            }
        }
    }

    /// How wide and tall the mark's ink is, in points: the pixels that are
    /// more than half covered.
    private static func ink(_ state: AgentSummary.State, size: CGFloat) throws -> CGSize {
        let image = try image(state, size: size)
        let scale = CGFloat(image.pixelsWide) / size
        var columns: Set<Int> = []
        var rows: Set<Int> = []
        for (y, row) in pixels(image).enumerated() {
            for (x, color) in row.enumerated() where color.alphaComponent > 0.5 {
                columns.insert(x)
                rows.insert(y)
            }
        }
        guard let left = columns.min(), let right = columns.max(), let top = rows.min(), let bottom = rows.max() else { return .zero }
        return CGSize(width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
    }

    @Test func eachMarkTakesTheBoxItsGiven() throws {
        for state in Self.states {
            for size: CGFloat in [14, 16] {
                let host = NSHostingView(rootView: AgentMark(state: state, size: size))
                #expect(host.fittingSize == CGSize(width: size, height: size), "\(state) at \(size)")
            }
        }
    }

    /// The circle-alert fills its box, while the ring's outer edge is 13/16
    /// of it. The Settings legends draw the marks as the sidebar does, so a
    /// mark that's the same size there depends on the mark itself.
    @Test func theWaitingCircleLooksAsBigAsTheRing() throws {
        let ring = try Self.ink(.working, size: 112)
        let circle = try Self.ink(.waiting(.permission), size: 112)
        #expect(ring.width > 80, "The ring's ink is \(ring.width) wide, so it wasn't drawn")
        #expect(abs(circle.width - ring.width) <= 3, "The circle is \(circle.width) wide and the ring \(ring.width)")
        #expect(abs(circle.height - ring.height) <= 3, "The circle is \(circle.height) tall and the ring \(ring.height)")
    }

    /// The orange quarter runs from the top to the right, as the canvas draws
    /// it, before it starts to turn. Only its round ends reach past.
    @Test func theOrangeQuarterStartsAtTheTop() throws {
        let image = try Self.image(.working, size: 112)
        var quarters = [0, 0, 0, 0] // top left, top right, bottom left, bottom right
        let pixels = Self.pixels(image)
        for (y, row) in pixels.enumerated() {
            for (x, color) in row.enumerated() where color.alphaComponent > 0.5 && color.redComponent - color.blueComponent > 0.4 {
                quarters[(y < pixels.count / 2 ? 0 : 2) + (x < row.count / 2 ? 0 : 1)] += 1
            }
        }
        #expect(quarters[1] > 10 * max(quarters[0], quarters[3]), "Orange pixels by quarter: \(quarters)")
        #expect(quarters[2] == 0, "Orange pixels by quarter: \(quarters)")
    }

    /// The ring's orange and gray are the ones SwiftUI draws in each
    /// appearance, as they were before the ring was layers.
    @Test func theRingFollowsTheAppearance() throws {
        /// The middle of the stroke at an angle clockwise from the top.
        func ring(_ appearance: NSAppearance.Name, at angle: CGFloat) throws -> NSColor {
            let pixels = Self.pixels(try Self.image(.working, size: 112, appearance: appearance))
            let side = CGFloat(pixels.count)
            let radius = side * 5.5 / 16
            return pixels[Int(side / 2 - radius * cos(angle))][Int(side / 2 + radius * sin(angle))]
        }
        func swiftUI(_ color: Color, _ appearance: NSAppearance.Name) throws -> NSColor {
            let pixels = Self.pixels(try Self.image(Rectangle().fill(color), size: 16, appearance: appearance))
            return pixels[pixels.count / 2][pixels.count / 2]
        }
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
        }
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let orange = try ring(appearance, at: .pi / 4)
            let gray = try ring(appearance, at: .pi)
            #expect(distance(orange, try swiftUI(Palette.action, appearance)) < 0.02, "\(appearance.rawValue): \(orange)")
            #expect(distance(gray, try swiftUI(AgentColors.ringTrack, appearance)) < 0.02, "\(appearance.rawValue): \(gray)")
        }
        #expect(distance(try ring(.aqua, at: .pi / 4), try ring(.darkAqua, at: .pi / 4)) > 0.1)
    }

    /// A theme chosen in Settings changes the app's appearance while the
    /// sidebar shows, and the ring's layers have colors of their own to change.
    @Test func theRingFollowsAChangeOfAppearance() throws {
        let size: CGFloat = 112
        let host = NSHostingView(rootView: AgentMark(state: .working, size: size))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: size, height: size), styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        func orange() throws -> NSColor {
            host.layoutSubtreeIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let pixels = Self.pixels(image)
            let side = CGFloat(pixels.count)
            let radius = side * 5.5 / 16
            return pixels[Int(side / 2 - radius * cos(.pi / 4))][Int(side / 2 + radius * sin(.pi / 4))]
        }
        let light = try orange()
        window.appearance = NSAppearance(named: .darkAqua)
        let dark = try orange()
        #expect(abs(dark.greenComponent - light.greenComponent) > 0.1, "Light \(light), then dark \(dark)")
    }

    /// Nothing turns where nobody can see it: out of a window, or in one
    /// that isn't on screen. A test can't put a window on someone's screen,
    /// so the test copy checked that it turns while it can be seen.
    @Test func theRingTurnsOnlyWhileItCanBeSeen() throws {
        let view = AgentRingView(frame: CGRect(x: 0, y: 0, width: 14, height: 14))
        view.spins = true
        #expect(!view.isTurning)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 14, height: 14), styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        #expect(!window.occlusionState.contains(.visible))
        #expect(!view.isTurning)
    }

    /// Each turn takes a second, goes on forever, and starts as far into a
    /// turn as the clock is, so that rings started at different moments are
    /// at the same angle at the same moment.
    @Test func ringsTurnInStep() {
        let first = AgentRingView.spin(at: 1000.25)
        let later = AgentRingView.spin(at: 1003.25)
        #expect(first.keyPath == "transform.rotation.z")
        #expect(first.duration == 1 && first.repeatCount == .infinity)
        #expect(first.toValue as? Double == 2 * .pi)
        #expect(abs(first.timeOffset - 0.25) < 1e-9 && abs(later.timeOffset - first.timeOffset) < 1e-9)
    }
}
