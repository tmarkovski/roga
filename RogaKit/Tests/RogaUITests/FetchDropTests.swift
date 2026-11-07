import CoreGraphics
import Foundation
import Testing
@testable import RogaUI

struct FetchDropTests {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    let duration = FetchDropRun.duration

    @Test func aDropStartsAndEndsWithTheIconAtRest() {
        #expect(FetchDropRun.curve(0) == 0)
        #expect(abs(FetchDropRun.curve(1) - 1) < 0.000001)
    }

    @Test func theStripOnlyEverMovesDownAndNeverJumps() {
        let phases = stride(from: 0.0, through: 1.0, by: 1.0 / 120).map(FetchDropRun.curve)
        for (before, after) in zip(phases, phases.dropFirst()) {
            #expect(after >= before)
            #expect(after - before < 0.03)
        }
    }

    /// The house is in the middle of the button halfway through, and slows
    /// down there, rather than going straight past.
    @Test func theHouseSlowsDownInTheMiddle() {
        #expect(abs(FetchDropRun.curve(0.5) - 0.5) < 0.000001)
        let middle = FetchDropRun.curve(0.51) - FetchDropRun.curve(0.49)
        let average = 0.02
        #expect(middle < average)
    }

    @Test func aQuickFetchStillShowsAWholeDrop() {
        var run = FetchDropRun(start: start)
        run.stop(at: start.addingTimeInterval(0.1))
        #expect(run.end == start.addingTimeInterval(duration))
        #expect(run.isRunning(at: start.addingTimeInterval(duration - 0.01)))
        #expect(!run.isRunning(at: start.addingTimeInterval(duration)))
    }

    @Test func aFetchThatStopsStraightAwayStillShowsAWholeDrop() {
        var run = FetchDropRun(start: start)
        run.stop(at: start)
        #expect(run.end == start.addingTimeInterval(duration))
    }

    @Test func theRunEndsWhenTheDropItsOnEnds() {
        var run = FetchDropRun(start: start)
        run.stop(at: start.addingTimeInterval(duration * 2.3))
        #expect(run.end == start.addingTimeInterval(duration * 3))
    }

    @Test func stoppingAgainDoesntMoveTheEnd() {
        var run = FetchDropRun(start: start)
        run.stop(at: start.addingTimeInterval(0.1))
        run.stop(at: start.addingTimeInterval(duration * 1.5))
        #expect(run.end == start.addingTimeInterval(duration))
    }

    @Test func theIconIsAtRestOnceTheRunHasEnded() {
        var run = FetchDropRun(start: start)
        run.stop(at: start.addingTimeInterval(0.1))
        #expect(run.dropped(at: start.addingTimeInterval(duration * 0.5)) > 0)
        #expect(run.dropped(at: start.addingTimeInterval(duration)) == 0)
        #expect(run.dropped(at: start.addingTimeInterval(duration * 1.5)) == 0)
    }

    @Test func aRunThatHasntStoppedKeepsDropping() {
        let run = FetchDropRun(start: start)
        let first = run.dropped(at: start.addingTimeInterval(duration * 0.25))
        let fifth = run.dropped(at: start.addingTimeInterval(duration * 4.25))
        #expect(first > 0)
        #expect(abs(first - fifth) < 0.000001)
    }

    // MARK: The hanging house

    /// The thread is tied to the chimney, which is the top of the house.
    @Test func theHouseHangsFromItsChimney() {
        let frame = HangingHouse.frame(thickness: 1)
        #expect(HangingHouse.knot.y - frame.minY < 12)
        #expect(HangingHouse.thread.maxY > HangingHouse.knot.y)
    }

    /// Its legs hang below the body and spread apart.
    @Test func theLegsHangDownAndSpreadApart() {
        let pose = HangingHouse.pose
        for leg in [pose.rearLeg, pose.frontLeg] {
            #expect(leg.ankle.y > leg.hip.y + HangingHouse.legLength * 0.7)
        }
        #expect(pose.rearLeg.ankle.x < pose.rearLeg.hip.x)
        #expect(pose.frontLeg.ankle.x > pose.frontLeg.hip.x)
    }

    /// Every joint and toe, drawn as thick as it is at the size of the button,
    /// is inside the frame the view sizes itself by.
    @Test func everythingButTheThreadFitsTheFrame() {
        let thickness = 1.32
        let frame = HangingHouse.frame(thickness: thickness)
        let pose = HangingHouse.pose
        for point in pose.rearLeg.points + pose.frontLeg.points {
            #expect(frame.insetBy(dx: HouseRig.toeWidth * thickness / 2 - 0.001, dy: HouseRig.toeWidth * thickness / 2 - 0.001).contains(point))
        }
    }
}
