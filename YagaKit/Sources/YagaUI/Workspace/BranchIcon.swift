import AppKit
import SwiftUI

/// The icons for what can be done with a branch, drawn from the commit graph
/// (decision 19). A solid node is the branch you're on, and an arrow says which
/// way commits go: Pull's lands on the node and Push's leaves it. Fetch's node is
/// hollow, because a fetch leaves the branch alone.
enum BranchIcon {
    case fetch
    case pull
    case push
    case branch
    /// No icon, for a menu item that lines up with the ones that have one.
    case blank

    /// The icon, in the color of whatever it's in.
    var image: Image {
        Image(nsImage: Self.images[self]!).renderingMode(.template)
    }

    private static let size = 16.0
    private static let images: [BranchIcon: NSImage] = [
        .fetch: draw { line(8, 2.2, to: 8, 7.6); arrowhead(5.6, 5.4, tip: 8, 7.8, 10.4, 5.4); ring(8, 12.4, 2.2) },
        .pull: draw { line(8, 2, to: 8, 8.4); arrowhead(5.2, 5.8, tip: 8, 8.6, 10.8, 5.8); dot(8, 12.6, 2.2) },
        .push: draw { line(8, 10.4, to: 8, 2.6); arrowhead(5.2, 5.4, tip: 8, 2.6, 10.8, 5.4); dot(8, 12.6, 2.2) },
        .branch: draw {
            dot(5, 12.6, 2.2)
            line(5, 10.4, to: 5, 2.5)
            let fork = NSBezierPath()
            fork.move(to: NSPoint(x: 5, y: 8.6))
            fork.curve(to: NSPoint(x: 11, y: 4.7), controlPoint1: NSPoint(x: 5, y: 6), controlPoint2: NSPoint(x: 11, y: 7))
            stroke(fork)
            ring(11, 3.2, 1.6)
        },
        .blank: draw {},
    ]

    private static func draw(_ drawing: @escaping @Sendable () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            NSColor.black.set()
            drawing()
            return true
        }
        image.isTemplate = true
        return image
    }

    nonisolated private static func stroke(_ path: NSBezierPath) {
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    nonisolated private static func line(_ x1: CGFloat, _ y1: CGFloat, to x2: CGFloat, _ y2: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x1, y: y1))
        path.line(to: NSPoint(x: x2, y: y2))
        stroke(path)
    }

    nonisolated private static func arrowhead(_ x1: CGFloat, _ y1: CGFloat, tip x2: CGFloat, _ y2: CGFloat, _ x3: CGFloat, _ y3: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x1, y: y1))
        path.line(to: NSPoint(x: x2, y: y2))
        path.line(to: NSPoint(x: x3, y: y3))
        stroke(path)
    }

    nonisolated private static func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    nonisolated private static func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
        circle(x, y, radius).fill()
    }

    nonisolated private static func ring(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
        stroke(circle(x, y, radius))
    }
}
