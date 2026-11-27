import AgentHooks
import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import RogaUI

/// The agents' marks: each takes the box it's given, the waiting circle looks
/// about as big as the windows at work wherever a mark is drawn, the windows follow
/// the appearance, and the light in the branch row's words runs only while
/// someone can see it. `HouseWindowLayerViewTests` has the windows' own tests.
struct AgentMarkTests {
    static let states: [AgentSummary.State] = [.working, .waiting(.question), .finished]

    /// A mark drawn in a window that's never shown, the way the sidebar hosts
    /// it. `ImageRenderer` can't draw the windows, which are an `NSView`.
    private static func image(
        _ state: AgentSummary.State, size: CGFloat, animation: HouseWindowAnimation = .windowChase,
        appearance: NSAppearance.Name = .aqua
    ) throws -> NSBitmapImageRep {
        try image(AgentMark(state: state, size: size, animation: animation), size: size, appearance: appearance)
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
    private static func ink(
        _ state: AgentSummary.State, size: CGFloat, animation: HouseWindowAnimation = .windowChase
    ) throws -> CGSize {
        let image = try image(state, size: size, animation: animation)
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
                let host = NSHostingView(rootView: AgentMark(state: state, size: size, animation: .windowChase))
                #expect(host.fittingSize == CGSize(width: size, height: size), "\(state) at \(size)")
            }
        }
    }

    /// The upright windows at rest are three quarters of the box across, and
    /// a little narrower and shorter than the waiting circle, so that their
    /// solid panes look about as big as its line. The Settings legends draw
    /// the marks as the sidebar does, so a mark that's the same size there
    /// depends on the mark itself.
    @Test func theWindowsLookAsBigAsTheWaitingCircle() throws {
        let windows = try Self.ink(.working, size: 112, animation: .windowChase)
        let circle = try Self.ink(.waiting(.permission), size: 112)
        #expect(abs(windows.width - 0.75 * 112) <= 2, "The windows' ink is \(windows.width) wide")
        #expect(windows.height > 0.6 * 112, "The windows' ink is \(windows.height) tall, so they weren't drawn upright")
        #expect(windows.width < circle.width && windows.height < circle.height, "The circle is \(circle) and the windows \(windows)")
    }

    /// A theme chosen in Settings changes the app's appearance while the
    /// sidebar shows, and the windows' layers have colors of their own to
    /// change.
    @Test func theWindowsFollowAChangeOfAppearance() throws {
        let size: CGFloat = 112
        let host = NSHostingView(rootView: AgentMark(state: .working, size: size, animation: .windowChase))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: size, height: size), styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        /// The middle of the bottom right pane, which is at rest in the
        /// chase's still frame.
        func pane() throws -> NSColor {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let bounds = HouseOutline.Pane.bottomRight.path.boundingRect
            let reach = size * AgentMark.windowReach
            let placement = HouseWindowFigure.placement(in: CGSize(width: reach, height: reach), rotation: .zero)
                .concatenating(CGAffineTransform(translationX: (size - reach) / 2, y: (size - reach) / 2))
            let middle = CGPoint(x: bounds.midX, y: bounds.midY).applying(placement)
            let scale = CGFloat(image.pixelsWide) / size
            return try #require(image.colorAt(x: Int(middle.x * scale), y: Int(middle.y * scale))?.usingColorSpace(.sRGB))
        }
        /// The resting orange as SwiftUI draws it in this appearance.
        func resting(dark: Bool) throws -> NSColor {
            let color = HouseWindowColors(dark: dark).fill(warmth: 0)
            let image = try Self.image(Rectangle().fill(color), size: 16)
            return try #require(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        }
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
        }
        let light = try pane()
        window.appearance = NSAppearance(named: .darkAqua)
        let dark = try pane()
        #expect(distance(light, try resting(dark: false)) < 0.02, "Light \(light)")
        #expect(distance(dark, try resting(dark: true)) < 0.02, "Dark \(dark)")
        #expect(distance(light, dark) > 0.05, "Light \(light), then dark \(dark)")
    }

    /// The light in the branch row's words, which stands in for the windows
    /// there, runs only while someone can see it, as the windows play. A test
    /// can't put a window on someone's screen, so the test copy checked that
    /// it runs while it can be seen.
    @Test func theLightInTheWordsRunsOnlyWhileItCanBeSeen() throws {
        let view = TextShimmerView(frame: CGRect(x: 0, y: 0, width: 200, height: 16))
        view.words = TextShimmerView.Words(text: "Run the test suite", font: .systemFont(ofSize: 13))
        view.layoutSubtreeIfNeeded()
        #expect(!view.isShimmering)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 16), styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        #expect(!window.occlusionState.contains(.visible))
        #expect(!view.isShimmering)
    }

    /// Each pass crosses the words in about two and a half seconds and goes on
    /// forever.
    @Test func theLightCrossesTheWordsOverAndOver() {
        let pass = TextShimmerView.shimmer(from: -20, to: 140)
        #expect(pass.keyPath == "position.x")
        #expect(pass.fromValue as? CGFloat == -20)
        #expect(pass.toValue as? CGFloat == 140)
        #expect(pass.duration == 2.4)
        #expect(pass.repeatCount == .infinity)
    }
}
