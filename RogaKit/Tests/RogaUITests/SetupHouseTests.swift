import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import RogaUI

/// The house's way from one place in setup to another: a leap between
/// Welcome and the floor, and a run along the floor.
@Suite struct SetupHouseTests {
    let welcome = SetupHouseSpot(foot: CGPoint(x: 640, y: 320), height: 168)
    let start = SetupHouseSpot(foot: CGPoint(x: 90, y: 770), height: 46)
    let next = SetupHouseSpot(foot: CGPoint(x: 365, y: 770), height: 46)

    /// A moment every sixtieth of a second until the trip is over.
    func moments(_ trip: SetupHouseTrip, to: SetupHouseSpot) -> [SetupHouseMoment] {
        stride(from: 0, through: trip.duration, by: 1.0 / 60).map { trip.moment(at: $0, to: to) }
    }

    func points(_ pose: HousePose) -> [CGPoint] {
        pose.rearLeg.points + pose.frontLeg.points
    }

    @Test func aChangeOfSizeIsALeapAndTheSameSizeIsARun() {
        #expect(SetupHouseTrip(from: welcome, to: start).kind == .leap)
        #expect(SetupHouseTrip(from: start, to: welcome).kind == .leap)
        #expect(SetupHouseTrip(from: start, to: next).kind == .run)
        #expect(SetupHouseTrip(from: next, to: start).kind == .run)
    }

    @Test(arguments: [0, 1, 2, 3])
    func itStartsWhereItWasAndEndsStandingWhereItIsGoing(_ which: Int) {
        let (from, to) = [(welcome, start), (start, welcome), (start, next), (next, start)][which]
        let trip = SetupHouseTrip(from: from, to: to)
        let first = trip.moment(at: 0, to: to)
        #expect(first.spot == from)
        #expect(first.pose == .mark)
        #expect(first.facing == 1)
        let last = trip.moment(at: trip.duration, to: to)
        #expect(last == SetupHouseMoment(spot: to, pose: .mark, facing: 1))
        // It's where it's going before it starts to rock.
        let arrived = trip.moment(at: trip.travelTime, to: to)
        #expect(abs(arrived.spot.foot.x - to.foot.x) < 0.001)
        #expect(abs(arrived.spot.foot.y - to.foot.y) < 0.001)
        #expect(abs(arrived.spot.height - to.height) < 0.001)
    }

    @Test func itIsQuick() {
        #expect(SetupHouseTrip(from: welcome, to: start).travelTime < 0.5)
        #expect(SetupHouseTrip(from: start, to: next).travelTime < 0.65)
        // Even from one end of a wide window to the other.
        let far = SetupHouseSpot(foot: CGPoint(x: 2400, y: 770), height: 46)
        #expect(SetupHouseTrip(from: start, to: far).travelTime < 0.9)
        #expect(SetupHouseTrip(from: start, to: far).travelTime > SetupHouseTrip(from: start, to: next).travelTime)
    }

    @Test(arguments: [false, true])
    func aRunStaysOnTheFloorAndNeverTurnsBack(_ goesBack: Bool) {
        let (from, to) = goesBack ? (next, start) : (start, next)
        let trip = SetupHouseTrip(from: from, to: to)
        var previous = from.foot.x
        for moment in moments(trip, to: to) {
            #expect(moment.spot.foot.y == to.foot.y)
            #expect(moment.spot.height == to.height)
            let x = moment.spot.foot.x
            #expect(goesBack ? x <= previous + 0.001 : x >= previous - 0.001)
            previous = x
        }
    }

    @Test func aRunIsStillMovingWhenItStops() {
        let before = SetupHouseTrip.progress(0.98)
        #expect(SetupHouseTrip.progress(0) == 0)
        #expect(SetupHouseTrip.progress(1) == 1)
        // A fifth as fast as it would be going at an even pace, or more.
        #expect((1 - before) / 0.02 > 0.2)
        // And it's fastest in the middle.
        let middle = (SetupHouseTrip.progress(0.5) - SetupHouseTrip.progress(0.48)) / 0.02
        #expect(middle > (1 - before) / 0.02)
        #expect(middle > SetupHouseTrip.progress(0.02) / 0.02)
    }

    @Test func itRunsWithItsLegsAndStandsAsTheMarkAtBothEnds() {
        let trip = SetupHouseTrip(from: start, to: next)
        let run = StrideMotion.run
        // It runs a whole number of cycles, from the stride nearest the
        // mark's and back to it.
        #expect(trip.cycles == 2)
        let middle = trip.moment(at: trip.travelTime / 2, to: next)
        #expect(middle.pose == run.pose(at: (SetupHouseTrip.stride + 1) * run.duration))
        #expect(middle.pose.body.lean > 0)
        // Which is the one with the front foot down ahead and the rear one
        // up behind, so there's little to change at either end.
        let nearest = run.pose(at: SetupHouseTrip.stride * run.duration)
        let mark = HousePose.mark
        #expect(abs(nearest.frontLeg.ankle.x - mark.frontLeg.ankle.x) < 60)
        #expect(abs(nearest.rearLeg.ankle.x - mark.rearLeg.ankle.x) < 60)
        #expect(nearest.rearLeg.ankle.y < nearest.frontLeg.ankle.y)
        // A longer run takes more of them rather than longer ones.
        let far = SetupHouseSpot(foot: CGPoint(x: 700, y: 770), height: 46)
        #expect(SetupHouseTrip(from: start, to: far).cycles == 3)
    }

    @Test func itFacesTheWayItRunsAndTurnsToFaceOnAgain() {
        let trip = SetupHouseTrip(from: next, to: start)
        #expect(trip.goesBack)
        #expect(trip.moment(at: trip.travelTime / 2, to: start).facing == -1)
        #expect(trip.moment(at: trip.travelTime + SetupHouseTrip.settle - 0.01, to: start).facing == -1)
        #expect(trip.moment(at: trip.duration, to: start).facing == 1)
        // Going on, it never turns.
        let on = SetupHouseTrip(from: start, to: next)
        #expect(moments(on, to: next).allSatisfy { $0.facing == 1 })
        #expect(on.duration < trip.duration)
    }

    /// A house that's sent somewhere else on its way carries on from the way
    /// it faced.
    @Test func itTurnsFromTheWayItFaced() {
        let trip = SetupHouseTrip(from: start, facing: -1, to: next)
        #expect(trip.moment(at: 0, to: next).facing == -1)
        #expect(trip.moment(at: SetupHouseTrip.turn, to: next).facing == 1)
    }

    @Test func itRocksForwardOutOfARunAndLessEachTime() {
        let trip = SetupHouseTrip(from: start, to: next)
        let leans = stride(from: trip.travelTime, through: trip.duration, by: 1.0 / 120).map {
            trip.moment(at: $0, to: next).pose.body.lean
        }
        let forward = leans.max() ?? 0
        let back = leans.min() ?? 0
        #expect(forward > 7)
        #expect(back < -1.5)
        #expect(-back < forward / 2)
        // Forward comes first.
        #expect(leans.firstIndex(of: forward) ?? 0 < leans.firstIndex(of: back) ?? 0)
        #expect(leans.last == 0)
    }

    @Test func aDropTipsItBackAndALeapUpHardlyRocksIt() {
        let down = SetupHouseTrip(from: welcome, to: start)
        let afterDrop = stride(from: down.travelTime, through: down.duration, by: 1.0 / 120).map {
            down.moment(at: $0, to: start).pose.body.lean
        }
        #expect((afterDrop.min() ?? 0) < -4)
        let up = SetupHouseTrip(from: start, to: welcome)
        let afterLeap = stride(from: up.travelTime, through: up.duration, by: 1.0 / 120).map {
            abs(up.moment(at: $0, to: welcome).pose.body.lean)
        }
        #expect((afterLeap.max() ?? 0) < 3)
    }

    /// Welcome's spot is the top of the leap: the house falls from rest there
    /// and comes to rest there, and it's moving when it meets the floor.
    @Test func aLeapFallsFasterAndRisesSlower() {
        let down = SetupHouseTrip(from: welcome, to: start)
        let step = 0.01
        func fall(_ trip: SetupHouseTrip, to: SetupHouseSpot, at time: Double) -> Double {
            abs(trip.moment(at: time + step, to: to).spot.foot.y - trip.moment(at: time, to: to).spot.foot.y)
        }
        #expect(fall(down, to: start, at: 0) < fall(down, to: start, at: down.travelTime - 2 * step) / 10)
        let up = SetupHouseTrip(from: start, to: welcome)
        #expect(fall(up, to: welcome, at: up.travelTime - 2 * step) < fall(up, to: welcome, at: 0) / 10)
        // It's one size or the other, or between them, all the way.
        for moment in moments(down, to: start) + moments(up, to: welcome) {
            #expect(moment.spot.height >= start.height - 0.001)
            #expect(moment.spot.height <= welcome.height + 0.001)
        }
    }

    @Test func theWindowCanChangeWhileItIsOnItsWay() {
        let trip = SetupHouseTrip(from: start, to: next)
        let moved = SetupHouseSpot(foot: CGPoint(x: 500, y: 900), height: 46)
        #expect(trip.moment(at: trip.duration, to: moved).spot == moved)
        #expect(trip.moment(at: trip.travelTime, to: moved).spot.foot.x == 500)
    }

    @Test(arguments: [0, 1, 2, 3])
    func nothingJumpsBetweenFrames(_ which: Int) {
        let (from, to) = [(welcome, start), (start, welcome), (start, next), (next, start)][which]
        let trip = SetupHouseTrip(from: from, to: to)
        let all = moments(trip, to: to)
        // In the mark's coordinates, where the house is 570 tall. A running
        // foot covers the most in a frame, which is 7 points on the floor.
        for (before, after) in zip(all, all.dropFirst()) {
            #expect(abs(after.pose.body.lean - before.pose.body.lean) < 4)
            for (first, second) in zip(points(before.pose), points(after.pose)) {
                #expect(hypot(first.x - second.x, first.y - second.y) < 90)
            }
            #expect(abs(after.facing - before.facing) < 0.5)
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func everyPoseFitsInTheFrame(_ which: Int) {
        let (from, to) = [(welcome, start), (start, welcome), (start, next), (next, start)][which]
        let trip = SetupHouseTrip(from: from, to: to)
        let frame = HouseRig.frame
        let legRadius = HouseRig.legWidth / 2
        let toeRadius = HouseRig.toeWidth / 2
        for moment in moments(trip, to: to) {
            let pose = moment.pose
            #expect(frame.contains(HouseOutline.body.applying(pose.body.transform).boundingRect))
            for leg in [pose.rearLeg, pose.frontLeg] {
                for joint in [leg.hip, leg.knee, leg.hock, leg.ankle] {
                    #expect(frame.insetBy(dx: legRadius, dy: legRadius).contains(joint))
                }
                for toe in leg.toes {
                    #expect(frame.insetBy(dx: toeRadius, dy: toeRadius).contains(toe))
                }
            }
        }
    }

    @Test func aPoseMixesFromOneToAnother() {
        let run = StrideMotion.run.pose(at: 0.1)
        #expect(HousePose.mark.mixed(with: run, by: 0) == .mark)
        let all = HousePose.mark.mixed(with: run, by: 1)
        #expect(all.body == run.body)
        for (mixed, wanted) in zip(points(all), points(run)) {
            #expect(hypot(mixed.x - wanted.x, mixed.y - wanted.y) < 0.001)
        }
        let half = HousePose.mark.mixed(with: run, by: 0.5)
        #expect(abs(half.body.lean - run.body.lean / 2) < 0.001)
        #expect(abs(half.frontLeg.ankle.x - (HousePose.mark.frontLeg.ankle.x + run.frontLeg.ankle.x) / 2) < 0.001)
    }

    @Test func tippingForwardKeepsTheFrontToesOnTheFloor() {
        let mark = HousePose.mark
        let lowest = mark.frontLeg.toes.map(\.y).max() ?? 0
        for degrees in [2.0, 5, 8] {
            let tipped = SetupHouseTrip.tipped(degrees)
            #expect(abs(tipped.body.lean - degrees) < 0.001)
            // Within a point or so at the size it's drawn.
            #expect(abs((tipped.frontLeg.toes.map(\.y).max() ?? 0) - lowest) < 14)
        }
        #expect(SetupHouseTrip.tipped(0) == mark)
    }
}
