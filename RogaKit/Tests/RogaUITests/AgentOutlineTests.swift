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

    /// Every band of the light ends at the front, all the way along, or the light
    /// would come apart as it moves.
    @Test func theBandsEndTogether() throws {
        let route = AgentOutlineView.route(for: .outline(cornerRadius: 7), size: Self.button)
        func values(_ band: AgentOutlineView.Band) throws -> (start: Double, end: Double, endTo: Double) {
            let group = AgentOutlineView.trip(of: band, on: route, looping: true, now: 0)
            let animations = try #require(group.animations as? [CABasicAnimation])
            let start = try #require(animations.first { $0.keyPath == "strokeStart" })
            let end = try #require(animations.first { $0.keyPath == "strokeEnd" })
            return (try #require(start.fromValue as? CGFloat), try #require(end.fromValue as? CGFloat), try #require(end.toValue as? CGFloat))
        }
        let bands = try AgentOutlineView.bands.map(values)
        #expect(bands.first?.start == 0)
        #expect(zip(bands, bands.dropFirst()).allSatisfy { $0.start < $1.start })
        #expect(bands.allSatisfy { $0.end == route.trail && $0.endTo == route.trail + route.distance && $0.start < $0.end })
    }

    /// Stacked up, the bands climb from nothing to full strength in equal steps,
    /// so no one place along the light reads as where it changes.
    @Test func theLightBrightensInEvenSteps() {
        var strength: CGFloat = 0
        var steps: [CGFloat] = []
        for band in AgentOutlineView.bands {
            let next = band.opacity + (1 - band.opacity) * strength
            steps.append(next - strength)
            strength = next
        }
        #expect(abs(strength - 1) < 1e-9)
        #expect(steps.allSatisfy { abs($0 - steps[0]) < 1e-9 })
    }

    /// The color warms up along the light and has arrived before the last band,
    /// which would otherwise stand out from the ones behind it.
    @Test func theColorChangesGradually() {
        let warmth = AgentOutlineView.bands.map(\.warmth)
        #expect(zip(warmth, warmth.dropFirst()).allSatisfy { $0 <= $1 && $1 - $0 < 0.1 })
        #expect(warmth.suffix(3).allSatisfy { $0 == 1 })
    }

    /// Going around twice is what lets the light cross where the path starts, so
    /// one trip is half of the path.
    @Test func oneTripIsOnceAround() {
        let route = AgentOutlineView.route(for: .outline(cornerRadius: 7), size: Self.button)
        #expect(route.distance == 0.5)
        let perimeter = 2 * (150 + 24) - 8 * 7 + 2 * CGFloat.pi * 7
        #expect(abs(route.trail - perimeter * 0.32 / (2 * perimeter)) < 1e-9)
        #expect(route.period == 1.7)
    }

    /// Around something large, the light keeps a size that reads as a light, and
    /// doesn't race.
    @Test func aLongWayAroundKeepsTheLightShort() {
        let route = AgentOutlineView.route(for: .outline(cornerRadius: 6), size: CGSize(width: 900, height: 500))
        let perimeter = 2 * (900 + 500) - 8 * 6 + 2 * CGFloat.pi * 6
        #expect(abs(route.trail * 2 * perimeter - 210) < 1e-6)
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
        let band = AgentOutlineView.bands[0]
        let pass = AgentOutlineView.trip(of: band, on: route, looping: false, now: 1000)
        #expect(pass.duration == AgentOutlineView.passDuration && pass.repeatCount == 0 && pass.isRemovedOnCompletion)
        #expect(pass.animations?.contains { ($0 as? CAKeyframeAnimation)?.keyPath == "opacity" } == true)

        let first = AgentOutlineView.trip(of: band, on: route, looping: true, now: 1000.25)
        let later = AgentOutlineView.trip(of: band, on: route, looping: true, now: 1000.25 + 3 * route.period)
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
