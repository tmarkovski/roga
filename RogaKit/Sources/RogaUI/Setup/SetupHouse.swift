import SwiftUI

/// Where the house stands in setup's window and how tall it is: large in the
/// middle of Welcome, and small on the floor after that.
nonisolated struct SetupHouseSpot: Equatable, Sendable {
    /// The middle of the bottom edge of the house's frame, which is the floor
    /// under it.
    var foot: CGPoint
    var height: CGFloat

    var width: CGFloat {
        height * HouseRig.frame.width / HouseRig.frame.height
    }

    /// The top left corner of the house's frame.
    var origin: CGPoint {
        CGPoint(x: foot.x - width / 2, y: foot.y - height)
    }
}

/// The house at one moment of setup.
nonisolated struct SetupHouseMoment: Equatable, Sendable {
    var spot: SetupHouseSpot
    var pose: HousePose
    /// Which way it faces: 1 for the way setup goes on, -1 for the way back,
    /// and between the two while it turns around.
    var facing: Double
}

/// The house on its way from one spot to another. Between Welcome and the
/// floor it leaps, changing size on the way. Along the floor it runs, and
/// stops short enough to rock on its feet before it stands still.
nonisolated struct SetupHouseTrip: Equatable, Sendable {
    enum Kind: Sendable {
        case leap
        case run
    }

    let kind: Kind
    let from: SetupHouseSpot
    /// Which way the house faced when it set off.
    let facingFrom: Double
    /// Whether it runs back the way it came, which it turns around for.
    let goesBack: Bool
    /// Whether a leap goes down to the floor rather than up from it.
    let drops: Bool
    /// How long it takes to get there, before it rocks and stands still.
    let travelTime: TimeInterval
    /// How many cycles of its run it fits into a run. It's a whole number,
    /// so that the run ends in the stride it started in.
    let cycles: Double

    /// How long a leap takes, whatever the distance.
    static let leapTime = 0.46
    /// About how long the run's cycle takes here, which is quicker than its
    /// own pace, for a house with somewhere to be.
    static let cadence = 0.27
    /// Where in its cycle the run is closest to the stride the mark is drawn
    /// in, with the front foot down ahead and the rear one in the air behind.
    /// A run starts and ends there, so that the house has little to change
    /// to get into its run and out of it.
    static let stride = 0.5
    /// How long it takes to get into its run from standing, and out of it.
    static let launch = 0.07
    static let landing = 0.09
    /// How long it rocks for once it has stopped.
    static let settle = 0.5
    /// How long turning around takes.
    static let turn = 0.12

    /// A trip to `to`, which is where the house is going as the window is
    /// now. It can move while the house is on its way, so `moment` asks for
    /// it again.
    init(from: SetupHouseSpot, facing: Double = 1, to: SetupHouseSpot) {
        self.from = from
        facingFrom = facing
        let distance = abs(to.foot.x - from.foot.x)
        if abs(to.height - from.height) > 0.5 {
            kind = .leap
            goesBack = false
            drops = to.height < from.height
            travelTime = Self.leapTime
            cycles = 0
        } else {
            kind = .run
            goesBack = to.foot.x < from.foot.x
            drops = false
            // A longer run is faster, but not so much that it takes no
            // longer.
            travelTime = min(max(0.34 + distance / 1100, 0.42), 0.85)
            cycles = max(1, (travelTime / Self.cadence).rounded())
        }
    }

    /// When the house stands still again, facing the way setup goes.
    var duration: TimeInterval {
        travelTime + Self.settle + (goesBack ? Self.turn : 0)
    }

    /// Where the house is and how it stands this long after setting off.
    func moment(at elapsed: TimeInterval, to: SetupHouseSpot) -> SetupHouseMoment {
        guard elapsed < duration else {
            return SetupHouseMoment(spot: to, pose: .mark, facing: 1)
        }
        let time = max(0, elapsed)
        return SetupHouseMoment(spot: spot(at: time, to: to), pose: pose(at: time), facing: facing(at: time))
    }

    // MARK: Where it is

    private func spot(at time: TimeInterval, to: SetupHouseSpot) -> SetupHouseSpot {
        let share = min(1, time / travelTime)
        switch kind {
        case .run:
            let amount = Self.progress(share)
            return SetupHouseSpot(foot: Tween.mix(from.foot, to.foot, amount), height: to.height)
        case .leap:
            // The spot on Welcome is the top of the leap. From there the
            // house falls faster and faster while it keeps moving sideways,
            // and a leap up is the same path the other way, so it slows into
            // place.
            let (high, low) = drops ? (from, to) : (to, from)
            let fallen = drops ? share : 1 - share
            return SetupHouseSpot(
                foot: CGPoint(
                    x: Tween.mix(high.foot.x, low.foot.x, fallen),
                    y: Tween.mix(high.foot.y, low.foot.y, fallen * fallen)
                ),
                height: Tween.mix(high.height, low.height, Tween.smooth(fallen))
            )
        }
    }

    /// How far along a run is at this share of its time. It's quick off the
    /// mark, steady in the middle, and still moving when it stops, so that
    /// the stop has something to rock about.
    static func progress(_ share: Double) -> Double {
        let quick = 0.22
        let slowing = 0.72
        let speedAtTheEnd = 0.3
        guard share > 0 else { return 0 }
        guard share < 1 else { return 1 }
        let top = 1 / (quick / 2 + (slowing - quick) + (1 - slowing) * (1 + speedAtTheEnd) / 2)
        if share < quick {
            return top * share * share / (2 * quick)
        }
        if share < slowing {
            return top * (quick / 2 + share - quick)
        }
        let since = share - slowing
        let slope = (speedAtTheEnd - 1) * top / (1 - slowing)
        return top * (quick / 2 + slowing - quick) + top * since + slope * since * since / 2
    }

    // MARK: How it stands

    private func pose(at time: TimeInterval) -> HousePose {
        guard time < travelTime else {
            return Self.tipped(Self.sway(at: time - travelTime, first: swing))
        }
        guard kind == .run else { return .mark }
        let run = StrideMotion.run
        let running = run.pose(at: (Self.stride + time / travelTime * cycles) * run.duration)
        let into = Tween.smooth(min(1, time / Self.launch))
        let outOf = Tween.smooth(min(1, (travelTime - time) / Self.landing))
        return HousePose.mark.mixed(with: running, by: min(into, outOf))
    }

    /// How far it tips first when it stops, in degrees, where forward is
    /// positive, of which it gets to about two thirds. A run tips it forward,
    /// as far as the waddle does, which is as far as it can go and stay in
    /// its frame. A drop to the floor carries it back,
    /// since it lands moving away from the way it faces, and a leap up slows
    /// into place and leaves little to rock about.
    private var swing: Double {
        switch kind {
        case .run: 13
        case .leap: drops ? -10 : 4
        }
    }

    /// How far the house has tipped this long after it stopped: one way, back
    /// past upright, and less each time until it stands still.
    static func sway(at time: TimeInterval, first: Double) -> Double {
        guard time > 0, time < settle else { return 0 }
        return first * sin(2 * .pi * time / 0.36) * exp(-time / 0.3) * (1 - time / settle)
    }

    /// The mark's stride tipped over its feet by this many degrees. Tipping
    /// forward turns it over its front toes, so it rises to keep them on the
    /// floor.
    static func tipped(_ degrees: Double) -> HousePose {
        guard degrees != 0 else { return .mark }
        let anchor = CGPoint(x: 592, y: 659)
        let rise = 246 * sin(max(0, degrees) * .pi / 180)
        let tip = CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y - rise))
        return HousePose.mark.applying(tip)
    }

    // MARK: Which way it faces

    private func facing(at time: TimeInterval) -> Double {
        let toward: Double = goesBack ? -1 : 1
        if time < Self.turn {
            return Tween.mix(facingFrom, toward, Tween.smooth(time / Self.turn))
        }
        // It turns to face the way setup goes once it has stopped rocking.
        let stopped = travelTime + Self.settle
        guard goesBack, time > stopped else { return toward }
        return Tween.mix(-1, 1, Tween.smooth(min(1, (time - stopped) / Self.turn)))
    }
}

/// Where setup wants the house: which place, and where that is in the window
/// as it is now, if the window has room for it.
struct SetupHouseTarget: Equatable {
    enum Place: Equatable {
        case welcome
        /// How far along the floor, from 0 to 1.
        case floor(Double)
    }

    var place: Place
    var spot: SetupHouseSpot?
}

/// The one house setup has. It's drawn over the screens rather than in one of
/// them, so that it's the same house that shrinks from Welcome's middle onto
/// the floor, runs along it as setup goes on, and waddles on the spot while
/// Roga is busy. Someone who asked for less motion sees it stand where it
/// belongs.
struct SetupHouseLayer: View {
    let target: SetupHouseTarget
    let isBusy: Bool

    @State private var trip: SetupHouseTrip?
    @State private var tripStart = Date.distantPast
    /// When the house last started to waddle, which is when Roga got busy or
    /// when it arrived, whichever is later.
    @State private var waddleStart = Date.now
    /// The last spot the house had, which it fades out at when the window
    /// has no room for it any more.
    @State private var lastSpot: SetupHouseSpot?
    @State private var isIn = false
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        let isMoving = !reducesMotion && (trip != nil || isBusy)
        Color.clear
            .overlay(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isMoving)) { timeline in
                    if let moment = moment(at: timeline.date) {
                        HouseFigure(pose: moment.pose)
                            .frame(width: moment.spot.width, height: moment.spot.height)
                            // A scale of nothing has no way back, so it stops
                            // just short of edge on.
                            .scaleEffect(x: moment.facing < 0 ? min(moment.facing, -0.04) : max(moment.facing, 0.04), y: 1)
                            .offset(x: moment.spot.origin.x, y: moment.spot.origin.y)
                            .transaction { $0.animation = nil }
                    }
                }
                // Without the movement, the house fades out where it was and
                // in where it belongs.
                .id(reducesMotion && target.place == .welcome)
                .transition(.opacity)
            }
            .animation(SetupMotion.step(reducesMotion), value: target.place == .welcome)
            .opacity(target.spot == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.2), value: target.spot == nil)
            .setupEntrance(isIn, order: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: target, initial: true) { old, new in
                if let spot = new.spot {
                    lastSpot = spot
                    isIn = true
                }
                guard old.place != new.place, !reducesMotion, let from = old.spot, let to = new.spot else { return }
                // A house that's already on its way sets off from where it
                // has got to.
                let now = Date.now
                let standing = SetupHouseMoment(spot: from, pose: .mark, facing: 1)
                let current = trip.map { $0.moment(at: now.timeIntervalSince(tripStart), to: from) } ?? standing
                trip = SetupHouseTrip(from: current.spot, facing: current.facing, to: to)
                tripStart = now
            }
            .onChange(of: isBusy) {
                waddleStart = .now
            }
            .task(id: tripStart) {
                guard let trip, (try? await Task.sleep(for: .seconds(trip.duration))) != nil else { return }
                self.trip = nil
                waddleStart = .now
            }
    }

    private func moment(at date: Date) -> SetupHouseMoment? {
        guard let spot = target.spot ?? lastSpot else { return nil }
        if let trip, !reducesMotion {
            let elapsed = date.timeIntervalSince(tripStart)
            if elapsed < trip.duration {
                return trip.moment(at: elapsed, to: spot)
            }
        }
        guard isBusy, target.place != .welcome else {
            return SetupHouseMoment(spot: spot, pose: .mark, facing: 1)
        }
        // The waddle starts from upright, which is a quarter of the way
        // through it, rather than from as far back as it leans.
        let waddle = WaddleMotion()
        let still = waddle.stillPhase * waddle.duration
        let time = reducesMotion ? still : still + max(0, date.timeIntervalSince(waddleStart))
        return SetupHouseMoment(spot: spot, pose: waddle.pose(at: time), facing: 1)
    }
}
