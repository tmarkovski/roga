import IconUI
import SwiftUI

/// The Fetch button's icon, which slides down out of the button while a fetch
/// runs. The house follows it down, hanging by a thread from its chimney, and
/// then the icon comes back in from the top (decision 55). That repeats until
/// the fetch is done, and the drop it's on always finishes, so even a quick
/// fetch shows a whole one. Someone who asked for less motion sees the icon fade
/// in and out instead.
struct FetchDrop: View {
    /// The button's height, which is the window everything slides through.
    static let height: CGFloat = 28
    /// How tall the house is, from its chimney to its toes.
    static let houseHeight: CGFloat = 20
    /// How far apart the icon, the house and the next icon are. The icon has
    /// all but gone when the house's toes come in, and the house when the next
    /// icon's arrow does.
    static let spacing: CGFloat = 30

    let isFetching: Bool
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var run: FetchDropRun?

    var body: some View {
        Group {
            if reducesMotion {
                Icon.fetch.image
                    .symbolEffect(.pulse.wholeSymbol, options: .repeat(.continuous), isActive: isFetching)
            } else if let run {
                TimelineView(.animation) { timeline in
                    strip(dropped: run.dropped(at: timeline.date))
                }
            } else {
                Icon.fetch.image
            }
        }
        .frame(width: Self.height, height: Self.height)
        .clipped()
        .onChange(of: isFetching, initial: true) { _, isFetching in
            if isFetching {
                if let run, run.isRunning(at: .now) {
                    self.run?.end = nil
                } else {
                    run = FetchDropRun(start: .now)
                }
            } else {
                run?.stop(at: .now)
            }
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
