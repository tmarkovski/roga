import AgentHooks
import AppKit
import SwiftUI
import Testing
@testable import RogaUI

/// The agents' marks: each takes the box it's given, and the waiting circle
/// looks as big as the ring, wherever a mark is drawn.
struct AgentMarkTests {
    static let states: [AgentSummary.State] = [.working, .waiting(.question), .finished]

    /// A mark drawn at one pixel a point.
    private static func image(_ state: AgentSummary.State, size: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: AgentMark(state: state, size: size))
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    /// How wide and tall the mark's ink is, in points: the pixels that are
    /// more than half covered.
    private static func ink(_ state: AgentSummary.State, size: CGFloat) throws -> CGSize {
        let image = try image(state, size: size)
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var columns: Set<Int> = []
        var rows: Set<Int> = []
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 127 {
                columns.insert(x)
                rows.insert(y)
            }
        }
        guard let left = columns.min(), let right = columns.max(), let top = rows.min(), let bottom = rows.max() else { return .zero }
        return CGSize(width: right - left + 1, height: bottom - top + 1)
    }

    @Test func eachMarkTakesTheBoxItsGiven() throws {
        for state in Self.states {
            for size: CGFloat in [14, 16] {
                let image = try Self.image(state, size: size)
                #expect(CGFloat(image.width) == size && CGFloat(image.height) == size, "\(state) at \(size)")
            }
        }
    }

    /// The circle-alert fills its box, while the ring's outer edge is 13/16
    /// of it. The Settings legends draw the marks as the sidebar does, so a
    /// mark that's the same size there depends on the mark itself.
    @Test func theWaitingCircleLooksAsBigAsTheRing() throws {
        let ring = try Self.ink(.working, size: 112)
        let circle = try Self.ink(.waiting(.permission), size: 112)
        #expect(abs(circle.width - ring.width) <= 3, "The circle is \(circle.width) wide and the ring \(ring.width)")
        #expect(abs(circle.height - ring.height) <= 3, "The circle is \(circle.height) tall and the ring \(ring.height)")
    }
}
