import IconUI
import SwiftUI

/// A picture that the player can play. Each frame depends only on its time, so
/// playing, scrubbing and saving all draw the same frame for the same moment
/// (decision 62). The player knows nothing else about what's being drawn.
protocol ReplayPicture {
    /// How long it plays at normal speed, in seconds.
    var duration: Double { get }
    /// What VoiceOver reads in place of the picture.
    var summary: String { get }
    func draw(in context: GraphicsContext, size: CGSize, at time: Double, colorScheme: ColorScheme)
}

/// The clock of a replay. While it's playing, the time is worked out from the
/// date of each frame, so changing speed carries on from the same moment.
@Observable
final class ReplayPlayer {
    /// The speeds it offers, as multiples of normal speed.
    static let speeds = [0.5, 1, 2, 4]
    /// How far the left and right arrow keys jump, in seconds.
    static let jump = 2.0

    private(set) var duration = 0.0
    private(set) var isPlaying = false
    private(set) var speed = 1.0
    /// Goes up with every change to the clock, so that the view knows to work
    /// out again when the replay will end.
    private(set) var changes = 0

    /// The time at `anchorDate`, or the time it's stopped at.
    private var anchorTime = 0.0
    private var anchorDate: Date?

    /// Starts on a new picture. Someone who asked for less motion starts on
    /// its last frame, still.
    func load(duration: Double, reducesMotion: Bool, at date: Date = .now) {
        self.duration = duration
        anchorTime = reducesMotion ? duration : 0
        anchorDate = reducesMotion ? nil : date
        isPlaying = !reducesMotion
        changes += 1
    }

    /// Keeps the same place in a picture that has become longer or shorter.
    func changeDuration(to newDuration: Double, at date: Date = .now) {
        let fraction = duration > 0 ? time(at: date) / duration : 0
        duration = newDuration
        seek(to: fraction * newDuration, at: date)
    }

    /// Keeps the same moment in a picture whose end has moved, as when lines
    /// are counted and add a stop to the tour at the end. One that had got to
    /// the end stays at the end.
    func moveEnd(to newDuration: Double, at date: Date = .now) {
        guard newDuration != duration else { return }
        let current = time(at: date)
        let wasAtEnd = current >= duration
        duration = newDuration
        seek(to: wasAtEnd ? newDuration : current, at: date)
    }

    func time(at date: Date) -> Double {
        guard let anchorDate else { return anchorTime }
        return min(duration, anchorTime + date.timeIntervalSince(anchorDate) * speed)
    }

    /// Plays or pauses. Playing from the end starts again.
    func togglePlaying(at date: Date = .now) {
        if isPlaying {
            anchorTime = time(at: date)
            anchorDate = nil
            isPlaying = false
        } else {
            if anchorTime >= duration { anchorTime = 0 }
            anchorDate = date
            isPlaying = true
        }
        changes += 1
    }

    func restart(at date: Date = .now) {
        anchorTime = 0
        anchorDate = date
        isPlaying = true
        changes += 1
    }

    func seek(to time: Double, at date: Date = .now) {
        anchorTime = min(duration, max(0, time))
        anchorDate = isPlaying ? date : nil
        changes += 1
    }

    func jump(by seconds: Double, at date: Date = .now) {
        seek(to: time(at: date) + seconds, at: date)
    }

    func setSpeed(_ newSpeed: Double, at date: Date = .now) {
        // Carrying on from this moment keeps the picture from jumping.
        anchorTime = time(at: date)
        if isPlaying { anchorDate = date }
        speed = newSpeed
        changes += 1
    }

    /// Moves up or down through the speeds, stopping at either end.
    func stepSpeed(by steps: Int, at date: Date = .now) {
        let current = Self.speeds.firstIndex(of: speed) ?? 1
        setSpeed(Self.speeds[min(Self.speeds.count - 1, max(0, current + steps))], at: date)
    }

    /// Stops at the end, once the clock has got there.
    func stopIfFinished(at date: Date = .now) {
        guard isPlaying, time(at: date) >= duration else { return }
        anchorTime = duration
        anchorDate = nil
        isPlaying = false
        changes += 1
    }

    /// How long until it reaches the end, or nil when it's not playing.
    func timeToEnd(at date: Date = .now) -> Duration? {
        guard isPlaying else { return nil }
        return .seconds(max(0, duration - time(at: date)) / speed)
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    static func speedTitle(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
    }
}

/// Plays a picture: the picture itself, with the play button, the slider and
/// the speed under it, and room for what else belongs in that row.
struct ReplayPlayerView<Picture: ReplayPicture, Accessories: View>: View {
    let picture: Picture
    let player: ReplayPlayer
    @ViewBuilder let accessories: Accessories
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !player.isPlaying)) { timeline in
            let time = player.time(at: timeline.date)
            VStack(spacing: 0) {
                Canvas(opaque: true) { context, size in
                    picture.draw(in: context, size: size, at: time, colorScheme: colorScheme)
                }
                .accessibilityElement()
                .accessibilityLabel(picture.summary)
                .accessibilityAddTraits(.isImage)
                controls(time)
            }
        }
        .background { keys }
        .task(id: player.changes) {
            guard let remaining = player.timeToEnd() else { return }
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            player.stopIfFinished()
        }
    }

    private func controls(_ time: Double) -> some View {
        HStack(spacing: 10) {
            Button { player.togglePlaying() } label: {
                (player.isPlaying ? Icon.pause : Icon.play).image.frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.restart() } label: {
                Icon.rotateCcw.image.frame(width: 16)
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .help("Start Again")
            .accessibilityLabel("Start again")

            Slider(value: Binding(get: { time }, set: { player.seek(to: $0) }), in: 0 ... max(player.duration, 0.01))
                .controlSize(.small)
                .accessibilityLabel("Position in the replay")
                .accessibilityValue(ReplayPlayer.clock(time))

            Text("\(ReplayPlayer.clock(time)) / \(ReplayPlayer.clock(player.duration))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            Picker("Speed", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                ForEach(ReplayPlayer.speeds, id: \.self) { Text(ReplayPlayer.speedTitle($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Speed")
            .accessibilityLabel("Speed")

            accessories
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The arrow keys, which do what the slider and the speed do. They're
    /// buttons so that they work wherever the keyboard is in the window, and
    /// see-through because the controls they stand for are already showing.
    private var keys: some View {
        ZStack {
            Button("Back") { player.jump(by: -ReplayPlayer.jump) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward") { player.jump(by: ReplayPlayer.jump) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Faster") { player.stepSpeed(by: 1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("Slower") { player.stepSpeed(by: -1) }.keyboardShortcut(.downArrow, modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
