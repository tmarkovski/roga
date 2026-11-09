import AppKit
import QuartzCore
import Testing
@testable import RogaUI

/// The orange line around an agent's command and what's being worked on, and
/// the light that runs along it (decision 65).
struct AgentOutlineTests {
    private static let button = CGSize(width: 150, height: 24)

    /// Nothing moves where nobody can see it, or while nothing's going on. A test
    /// can't put a window on someone's screen, so the test copy checked that it
    /// moves while it can be seen.
    @Test func theLightMovesOnlyWhileItCanBeSeen() {
        let view = AgentOutlineView(frame: CGRect(origin: .zero, size: Self.button))
        view.layout()
        #expect(!view.isTraveling)
        view.isWorking = true
        view.isHovering = true
        #expect(!view.isTraveling)

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.button), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        #expect(!window.occlusionState.contains(.visible))
        #expect(!view.isTraveling)
    }

    @Test func itGetsOutOfTheWayOfClicks() {
        let view = AgentOutlineView(frame: CGRect(origin: .zero, size: Self.button))
        #expect(view.hitTest(CGPoint(x: 10, y: 10)) == nil)
    }

    /// The head and tail of the light end at the same place, all the way along,
    /// so that the head stays at the front.
    @Test func theHeadLeadsTheTrail() throws {
        let route = AgentOutlineView.route(for: .outline(cornerRadius: 7), size: Self.button)
        func values(_ part: AgentOutlineView.Part) throws -> (start: Double, end: Double, endTo: Double) {
            let group = AgentOutlineView.trip(of: part, on: route, looping: true, now: 0)
            let animations = try #require(group.animations as? [CABasicAnimation])
            let start = try #require(animations.first { $0.keyPath == "strokeStart" })
            let end = try #require(animations.first { $0.keyPath == "strokeEnd" })
            return (try #require(start.fromValue as? CGFloat), try #require(end.fromValue as? CGFloat), try #require(end.toValue as? CGFloat))
        }
        let trail = try values(.trail)
        let head = try values(.head)
        #expect(trail.end == head.end && trail.endTo == head.endTo)
        #expect(trail.start == 0)
        #expect(head.start > trail.start && head.start < head.end)
    }

    /// Going around twice is what lets the light cross where the path starts, so
    /// one trip is half of the path.
    @Test func oneTripIsOnceAround() {
        let route = AgentOutlineView.route(for: .outline(cornerRadius: 7), size: Self.button)
        #expect(route.distance == 0.5)
        let perimeter = 2 * (150 + 24) - 8 * 7 + 2 * CGFloat.pi * 7
        #expect(abs(route.trail - perimeter * 0.26 / (2 * perimeter)) < 1e-9)
        #expect(route.period == 1.7)
    }

    /// Around something large, the light keeps a size that reads as a light, and
    /// doesn't race.
    @Test func aLongWayAroundKeepsTheLightShort() {
        let route = AgentOutlineView.route(for: .outline(cornerRadius: 6), size: CGSize(width: 900, height: 500))
        let perimeter = 2 * (900 + 500) - 8 * 6 + 2 * CGFloat.pi * 6
        #expect(abs(route.trail * 2 * perimeter - 170) < 1e-6)
        #expect(abs(route.head * 2 * perimeter - 56) < 1e-6)
        #expect(route.period == 4)
    }

    /// The whole light is past the end of a straight run by the time it's done.
    @Test func alongTheTopItLeavesAtTheFarEnd() {
        let route = AgentOutlineView.route(for: .topEdge, size: CGSize(width: 520, height: 3))
        #expect(abs(route.trail + route.distance - 1) < 1e-9)
    }

    /// Under the pointer it goes around once and fades. While an agent works it
    /// goes on, in step with others that started at another moment.
    @Test func aPassEndsAndALoopDoesnt() {
        let route = AgentOutlineView.route(for: .outline(cornerRadius: 7), size: Self.button)
        let pass = AgentOutlineView.trip(of: .head, on: route, looping: false, now: 1000)
        #expect(pass.duration == AgentOutlineView.passDuration && pass.repeatCount == 0 && pass.isRemovedOnCompletion)
        #expect(pass.animations?.contains { ($0 as? CAKeyframeAnimation)?.keyPath == "opacity" } == true)

        let first = AgentOutlineView.trip(of: .head, on: route, looping: true, now: 1000.25)
        let later = AgentOutlineView.trip(of: .head, on: route, looping: true, now: 1000.25 + 3 * route.period)
        #expect(first.repeatCount == .infinity && !first.isRemovedOnCompletion)
        #expect(abs(first.timeOffset - later.timeOffset) < 1e-6)
    }

    /// The still line is the shape it surrounds, and a run along the top has none.
    @Test func eachShapeHasItsLine() throws {
        let bounds = CGRect(origin: .zero, size: Self.button)
        let around = AgentOutlineView.paths(for: .outline(cornerRadius: 7), in: bounds)
        let line = try #require(around.line)
        #expect(line.boundingBox.insetBy(dx: -0.5, dy: -0.5).integral == bounds)
        #expect(AgentOutlineView.paths(for: .topEdge, in: bounds).line == nil)
    }
}
