import IconUI
import SwiftUI

/// The Fetch button's icon, which slides down out of the button while a fetch
/// runs. The house follows it down, hanging by a thread from its chimney, and
/// then the icon comes back in from the top (decision 57). That repeats until
/// the fetch is done, and the drop it's on always finishes, so even a quick
/// fetch shows a whole one. Someone who asked for less motion, or who turned the
/// house off in Settings, sees the icon fade in and out instead (decision 112).
struct FetchDrop: View {
    /// The button's height, which is the window everything slides through.
    static let height: CGFloat = 32
    /// How tall the house is, from its chimney to its toes.
    static let houseHeight: CGFloat = 23
    /// How far apart the icon, the house and the next icon are. The icon has
    /// all but gone when the house's toes come in, and the house when the next
    /// icon's arrow does.
    static let spacing: CGFloat = 34

    let isFetching: Bool
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @AppStorage(UserDefaults.animatesHouseKey) private var animatesHouse = true
    /// The drops, which start only while the house is on, so that turning it
    /// back on during a fetch waits for the next one.
    @State private var run: FetchDropRun?

    var body: some View {
        Group {
            if let run, animatesHouse, !reducesMotion {
                TimelineView(.animation) { timeline in
                    strip(dropped: run.dropped(at: timeline.date))
                }
            } else {
                Icon.fetch.image
                    .symbolEffect(.pulse.wholeSymbol, options: .repeat(.continuous), isActive: isFetching)
            }
        }
        .frame(width: Self.height, height: Self.height)
        .clipped()
        .onChange(of: isFetching, initial: true) { _, isFetching in
            if isFetching {
                if let run, run.isRunning(at: .now) {
                    self.run?.end = nil
                } else if animatesHouse {
                    run = FetchDropRun(start: .now)
                }
            } else {
                run?.stop(at: .now)
            }
        }
        // Turning the house off takes it away at once, as the pulse takes over.
        .onChange(of: animatesHouse) { _, animatesHouse in
            if !animatesHouse { run = nil }
        }
        .task(id: run?.end) {
            guard let end = run?.end else { return }
            guard (try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))) != nil else { return }
            run = nil
        }
    }

    /// The icon, the house above it and the next icon above that, moved down by
    /// `dropped` of the way from one icon to the next.
    private func strip(dropped: Double) -> some View {
        let travel = dropped * 2 * Self.spacing
        return ZStack {
            Icon.fetch.image
                .offset(y: travel)
            HangingHouseFigure(height: Self.houseHeight)
                .offset(y: travel - Self.spacing)
            Icon.fetch.image
                .offset(y: travel - 2 * Self.spacing)
        }
    }
}

/// When a run of drops started, and once the fetch is done, when the last drop
/// ends.
nonisolated struct FetchDropRun: Equatable {
    /// How long one drop takes, from the icon leaving to it coming back.
    static let duration: TimeInterval = 1.4

    let start: Date
    var end: Date?

    /// Whether a drop is still under way, or more are to come.
    func isRunning(at date: Date) -> Bool {
        end.map { date < $0 } ?? true
    }

    /// How far through the drop it's on the strip has moved, from 0, with the
    /// icon at rest, to 1, with the next icon there instead. It's 0 again once
    /// the run has ended.
    func dropped(at date: Date) -> Double {
        guard isRunning(at: date) else { return 0 }
        let drops = max(0, date.timeIntervalSince(start)) / Self.duration
        return Self.curve(drops - drops.rounded(.down))
    }

    /// Ends the run when the drop it's on ends, and after one drop at least.
    mutating func stop(at date: Date) {
        guard end == nil else { return }
        let drops = max(1, (date.timeIntervalSince(start) / Self.duration).rounded(.up))
        end = start.addingTimeInterval(drops * Self.duration)
    }

    /// From 0 to 1 over a drop. The icon leaves and arrives gently, and the
    /// house slows down as it passes through the middle, so that it can be seen.
    static func curve(_ phase: Double) -> Double {
        Tween.mix(Tween.smooth(phase), Tween.through(0, 0.5, 1, phase), 0.5)
    }
}
