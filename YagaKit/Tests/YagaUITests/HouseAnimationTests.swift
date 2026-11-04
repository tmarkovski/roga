import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import YagaUI

@MainActor
struct HouseAnimationTests {
    /// A moment every sixtieth of a second, for two cycles and a bit.
    func times(_ motion: any HouseMotion) -> [TimeInterval] {
        stride(from: 0, through: motion.duration * 2.25, by: 1.0 / 60).map { $0 }
    }

    func points(_ pose: HousePose) -> [CGPoint] {
        pose.rearLeg.points + pose.frontLeg.points
    }

    func distance(_ first: CGPoint, _ second: CGPoint) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }

    func isLifted(_ leg: HouseLeg) -> Bool {
        let lowest = (leg.toes.map(\.y)).max() ?? 0
        return lowest < HouseRig.floor - HouseRig.toeWidth / 2 - 0.001
    }

    @Test(arguments: HouseAnimation.allCases)
    func endsWhereItStarts(_ animation: HouseAnimation) {
        let motion = animation.motion
        let first = motion.pose(at: 0)
        let last = motion.pose(at: motion.duration - 0.000001)
        #expect(abs(first.body.lean - last.body.lean) < 0.01)
        for (start, end) in zip(points(first), points(last)) {
            #expect(distance(start, end) < 0.01)
        }
    }

    @Test(arguments: HouseAnimation.allCases)
    func nothingJumpsBetweenFrames(_ animation: HouseAnimation) {
        let motion = animation.motion
        var previous = motion.pose(at: 0)
        for time in times(motion).dropFirst() {
            let pose = motion.pose(at: time)
            #expect(abs(pose.body.lean - previous.body.lean) < 4)
            for (before, after) in zip(points(previous), points(pose)) {
                #expect(distance(before, after) < 40)
            }
            previous = pose
        }
    }

    @Test(arguments: HouseAnimation.allCases)
    func everyPoseFitsInTheFrame(_ animation: HouseAnimation) {
        let motion = animation.motion
        let frame = HouseRig.frame
        let outline = HouseOutline.body
        for time in times(motion) {
            let pose = motion.pose(at: time)
            let house = outline.applying(pose.body.transform).boundingRect
            #expect(frame.contains(house))
            // The thickest the legs get, at the size of the title row.
            let thickness = HouseFigure.thickness(forHeight: 18)
            let legRadius = HouseRig.legWidth * thickness / 2
            let toeRadius = HouseRig.toeWidth * thickness / 2
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

    @Test(arguments: [HouseAnimation.push, .tugOfWar, .heave])
    func feetStayOnOrAboveTheFloor(_ animation: HouseAnimation) {
        let motion = animation.motion
        for time in times(motion) {
            let pose = motion.pose(at: time)
            for toe in pose.rearLeg.toes + pose.frontLeg.toes {
                #expect(toe.y <= HouseRig.floor - HouseRig.toeWidth / 2 + 0.001)
            }
        }
    }

    @Test(arguments: [HouseAnimation.push, .tugOfWar, .heave])
    func feetTakeTurnsAndNeverLiftTogether(_ animation: HouseAnimation) {
        let motion = animation.motion
        var rearLifted = false
        var frontLifted = false
        for time in times(motion) {
            let pose = motion.pose(at: time)
            #expect(!(isLifted(pose.rearLeg) && isLifted(pose.frontLeg)))
            rearLifted = rearLifted || isLifted(pose.rearLeg)
            frontLifted = frontLifted || isLifted(pose.frontLeg)
        }
        #expect(rearLifted)
        #expect(frontLifted)
    }

    /// A foot that's down moves with the floor, so it doesn't look like it's
    /// skating.
    @Test(arguments: [HouseAnimation.push, .tugOfWar, .heave])
    func aFootThatIsDownMovesWithTheFloor(_ animation: HouseAnimation) {
        let motion = animation.motion
        var previous = motion.pose(at: 0)
        for time in times(motion).dropFirst() {
            let pose = motion.pose(at: time)
            let floor = pose.floorTravel - previous.floorTravel
            for (before, after) in [(previous.rearLeg, pose.rearLeg), (previous.frontLeg, pose.frontLeg)] where !isLifted(before) && !isLifted(after) {
                #expect(abs(after.ankle.x - before.ankle.x - floor) < 0.5)
            }
            previous = pose
        }
    }

    @Test func pushingMovesTheFloorBackAndPullingMovesItForward() {
        #expect(StrideMotion.push.pose(at: 1).floorTravel < 0)
        #expect(StrideMotion.tugOfWar.pose(at: 1).floorTravel > 0)
        #expect(HeaveMotion().pose(at: 1).floorTravel > 0)
    }

    /// Pushing leans into it with the legs behind, and pulling leans away from
    /// it with the legs in front.
    @Test func theHouseLeansAndStandsTheWayItPullsOrPushes() {
        let push = StrideMotion.push.pose(at: 0.3)
        #expect(push.body.lean > 0)
        #expect(push.rearLeg.ankle.x < push.rearLeg.hip.x)
        #expect(push.frontLeg.ankle.x < push.frontLeg.hip.x)

        let pull = StrideMotion.tugOfWar.pose(at: 0.3)
        #expect(pull.body.lean < 0)
        #expect(pull.rearLeg.ankle.x > pull.rearLeg.hip.x)
        #expect(pull.frontLeg.ankle.x > pull.frontLeg.hip.x)

        let heave = HeaveMotion()
        let beforeHeaving = heave.pose(at: heave.windUpEnd * heave.duration)
        let afterHeaving = heave.pose(at: heave.heaveEnd * heave.duration)
        #expect(beforeHeaving.body.lean > 0)
        #expect(afterHeaving.body.lean < 0)
        #expect(afterHeaving.frontLeg.ankle.x > afterHeaving.frontLeg.hip.x)
    }

    @Test func aHeaveKeepsItsFeetDownWhileTheBodySwingsBack() {
        let heave = HeaveMotion()
        for phase in stride(from: heave.windUpEnd, through: 0.99, by: 0.01) {
            let pose = heave.pose(at: phase * heave.duration)
            #expect(!isLifted(pose.rearLeg))
            #expect(!isLifted(pose.frontLeg))
        }
    }

    @Test func theWaddleMovesTheWholeHouseAsOnePiece() {
        let motion = WaddleMotion()
        let mark = HousePose.mark
        let pose = motion.pose(at: motion.duration / 2)
        let hip = mark.frontLeg.hip
        let toe = mark.frontLeg.toes[0]
        // Rigid, so the distance between any two joints doesn't change.
        #expect(abs(distance(hip, toe) - distance(pose.frontLeg.hip, pose.frontLeg.toes[0])) < 0.001)
        #expect(abs(pose.body.lean - motion.swing) < 0.001)
    }

    @Test func aPoseCanBeMovedWholeWithoutLosingTheBody() {
        let turn = CGAffineTransform(rotationAngle: .pi / 6).translatedBy(x: 40, y: -10)
        let body = HouseBody(lean: 10, offset: CGVector(dx: 5, dy: 8))
        let moved = HousePose(body: body, rearLeg: HousePose.mark.rearLeg, frontLeg: HousePose.mark.frontLeg).applying(turn)
        let point = CGPoint(x: 700, y: 300)
        #expect(distance(moved.body.place(point), body.place(point).applying(turn)) < 0.001)
    }

    @Test func aLegGoesStraightWhenTheFootIsAtFullLength() {
        let hip = CGPoint(x: 600, y: 480)
        let foot = HouseFoot(x: 600, pitch: 0)
        let reach = foot.ankle.y - hip.y
        let straight = HouseLeg(hip: hip, foot: foot, length: reach, fold: 0.2)
        #expect(straight.knee.x == hip.x)
        #expect(straight.hock.x == hip.x)
        let folded = HouseLeg(hip: hip, foot: foot, length: reach * 1.3, fold: 0.2)
        // The knee bends forward and the hock bends back.
        #expect(folded.knee.x > hip.x)
        #expect(folded.hock.x < hip.x)
    }

    @Test func toesRiseWhenTheHeelDigsIn() {
        let flat = HouseFoot(x: 500, pitch: 0)
        let dug = HouseFoot(x: 500, pitch: -36)
        #expect(dug.toes[1].y < flat.toes[1].y)
    }

    @Test func theBodyIsTheMarksOutlineWithItsFourWindows() {
        var closed = 0
        HouseOutline.body.forEach { if case .closeSubpath = $0 { closed += 1 } }
        #expect(closed == 5)
        let bounds = HouseOutline.body.boundingRect
        #expect(abs(bounds.minX - 409) < 2)
        #expect(abs(bounds.maxX - 846.4) < 2)
        #expect(abs(bounds.minY - 151.8) < 2)
        #expect(abs(bounds.maxY - 511.5) < 2)
    }

    @Test func pushingAndPullingShowTheirDirectionAndTheRestDoNot() {
        #expect(BranchModel.Action.pushing.houseAnimation == .push)
        #expect(BranchModel.Action.forcePushing.houseAnimation == .push)
        #expect(BranchModel.Action.pulling.houseAnimation == .heave)
        #expect(BranchModel.Action.undoingPull.houseAnimation == .waddle)
        #expect(BranchModel.Action.aborting.houseAnimation == .waddle)
    }

    @Test func aFetchHasNoHouseToWaitFor() {
        #expect(BranchModel.Action.fetching.houseAnimation == nil)
        #expect(BranchModel.Action.fetching.timeToPlayHouse == .zero)
    }

    @Test func theWordsBesideTheHouseMoveTheWayItWorks() {
        #expect(WordsArrival(.push) == .fromLeft)
        #expect(WordsArrival(.heave) == .fromRight)
        #expect(WordsArrival(.waddle) == .fade)
    }

    @Test func playingOnceTakesOneCycleAtTheSpeed() {
        #expect(HouseAnimation.heave.timeToPlay(atSpeed: 1) == .seconds(1.5))
        #expect(HouseAnimation.heave.timeToPlay(atSpeed: 3) == .seconds(0.5))
        #expect(HouseAnimation.push.timeToPlay(atSpeed: 0.5) == .seconds(2.5))
    }

    @Test func theSpeedIsNormalUntilSomeoneSetsIt() throws {
        let name = "HouseAnimationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(defaults.houseAnimationSpeed == 1)
        defaults.set(2.5, forKey: UserDefaults.houseAnimationSpeedKey)
        #expect(defaults.houseAnimationSpeed == 2.5)
        // What @AppStorage would read as 3.
        defaults.set("3", forKey: UserDefaults.houseAnimationSpeedKey)
        #expect(defaults.houseAnimationSpeed == 3)
    }

    @Test func aStoredSpeedStaysWithinWhatSettingsOffers() {
        #expect(HouseAnimationView.clamped(2) == 2)
        #expect(HouseAnimationView.clamped(0) == HouseAnimationView.speeds.lowerBound)
        #expect(HouseAnimationView.clamped(50) == HouseAnimationView.speeds.upperBound)
    }

    @Test func changingTheSpeedCarriesOnFromTheSamePose() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var clock = HouseClock(startDate: start, startTime: 0.5)
        #expect(clock.time(at: start, speed: 2) == 0.5)
        #expect(clock.time(at: start.addingTimeInterval(1), speed: 2) == 2.5)

        let change = start.addingTimeInterval(1)
        clock.rebase(at: change, speed: 2)
        #expect(clock.time(at: change, speed: 0.5) == 2.5)
        #expect(clock.time(at: change.addingTimeInterval(2), speed: 0.5) == 3.5)
    }
}
