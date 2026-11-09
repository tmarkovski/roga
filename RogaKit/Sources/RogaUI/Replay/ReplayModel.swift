import AppKit
import CommitGraph
import GitCore
import RepositoryEngine
import SwiftUI
import UniformTypeIdentifiers

extension UserDefaults {
    static let replayShowsHouseKey = "replayShowsHouse"
}

/// One replay in its window: which commits it covers, how long it plays, and
/// the replay worked out from those.
@Observable
final class ReplayModel {
    /// Which commits behind the tip to replay.
    enum Scope: Hashable, Identifiable {
        case days(Int)
        case wholeHistory
        case afterTag(name: String, commit: CommitGraph.Position)

        var id: Self { self }

        var title: String {
            switch self {
            case .days(let days): "Last \(days) Days"
            case .wholeHistory: "Whole History"
            case .afterTag(let name, _): "Since \(name)"
            }
        }
    }

    enum Phase {
        case loading
        case ready(MetroMap)
        /// The range has no commits in it.
        case nothing
        case failed(String)
    }

    /// What's being saved, and how far along it is, from 0 to 1, or nil
    /// while it waits for something it can't measure.
    struct Saving: Equatable {
        var title: String
        var progress: Double?
    }

    struct Tag: Hashable {
        var name: String
        var commit: CommitGraph.Position
    }

    /// The ranges everyone gets. Tags add theirs.
    static let dayRanges = [7, 14, 30, 90, 365]
    /// The lengths it offers, in seconds.
    static let lengths = [30.0, 45, 60, 75, 90, 120]
    /// Where a replay starts, until someone picks something else.
    static let startingDays = 7
    static let startingLength = 45.0

    let session: RepositorySession
    let graph: CommitGraph
    let tip: CommitGraph.Position
    let branchName: String
    let tags: [Tag]
    let player = ReplayPlayer()

    private(set) var phase = Phase.loading
    /// Which commits it covers, once it's worked out where to start.
    private(set) var scope: Scope?
    private(set) var length = startingLength
    private(set) var saving: Saving?
    /// Whether the window offers the house at all. While it doesn't, the house
    /// stays out of playback and saved videos, whatever was last chosen, and
    /// the choice is kept for when the button comes back.
    static let offersHouse = false

    /// Whether the house walks along the line, which stays as it was left.
    var showsHouse = offersHouse && UserDefaults.standard.bool(forKey: UserDefaults.replayShowsHouseKey) {
        didSet {
            UserDefaults.standard.set(showsHouse, forKey: UserDefaults.replayShowsHouseKey)
            guard case .ready(var map) = phase else { return }
            map.showsHouse = showsHouse
            phase = .ready(map)
        }
    }
    /// Whether git is still counting the lines of the replay on screen, which
    /// plays without them until they're in.
    private(set) var isCountingLines = false

    private var replay: HistoryReplay?
    private var reducesMotion = false
    private var loading: Task<Void, Never>?
    private var counting: Task<Void, Never>?
    private var save: Task<Void, Never>?

    init(session: RepositorySession, graph: CommitGraph, tip: CommitGraph.Position, branchName: String, tags: [Tag]) {
        self.session = session
        self.graph = graph
        self.tip = tip
        self.branchName = branchName
        self.tags = tags
    }

    var repositoryName: String { session.location.name }

    /// The ranges every replay offers. The window adds one for each tag.
    var scopes: [Scope] {
        Self.dayRanges.map(Scope.days) + [.wholeHistory]
    }

    /// Loads the starting range, the first time the window shows.
    func start(reducesMotion: Bool) {
        self.reducesMotion = reducesMotion
        guard scope == nil else { return }
        scope = .days(Self.startingDays)
        load()
    }

    func choose(_ scope: Scope) {
        guard scope != self.scope else { return }
        self.scope = scope
        load()
    }

    /// Fits the replay to a new length, without working it out again.
    func choose(length: Double) {
        guard length != self.length else { return }
        self.length = length
        guard var replay else { return }
        replay.fit(to: length)
        self.replay = replay
        let map = MetroMap(replay: replay, repositoryName: repositoryName, showsHouse: showsHouse)
        phase = .ready(map)
        player.changeDuration(to: map.duration)
    }

    func stop() {
        loading?.cancel()
        counting?.cancel()
        save?.cancel()
    }

    private func range(for scope: Scope) -> HistoryReplay.CommitRange {
        switch scope {
        case .wholeHistory: .all
        // From the branch's newest commit rather than from today, so that a
        // quiet branch still shows the end of its history.
        case .days(let days): .since(time: graph.commitTime(at: tip) - Int64(days) * 86_400)
        case .afterTag(_, let commit): .after(commit)
        }
    }

    private func load() {
        guard let scope else { return }
        loading?.cancel()
        counting?.cancel()
        isCountingLines = false
        phase = .loading
        let range = range(for: scope)
        loading = Task { [session, graph, tip, branchName, length, repositoryName, showsHouse] in
            do {
                let replay = try await session.replay(of: tip, in: graph, range: range, mainLineName: branchName, length: length)
                guard !Task.isCancelled else { return }
                self.replay = replay
                guard !replay.commits.isEmpty else {
                    phase = .nothing
                    return
                }
                let map = MetroMap(replay: replay, repositoryName: repositoryName, showsHouse: showsHouse)
                phase = .ready(map)
                player.load(duration: map.duration, reducesMotion: reducesMotion)
                countLines(of: replay)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.dialogMessage)
            }
        }
    }

    /// Has git count each commit's lines in the background, and puts them in
    /// the picture once they're in, at the same place in the replay. A replay
    /// that can't have them plays on without them.
    private func countLines(of replay: HistoryReplay) {
        isCountingLines = true
        let commits = replay.commits.map(\.id)
        counting = Task { [session, repositoryName] in
            let counts = try? await session.lineCounts(of: commits)
            guard !Task.isCancelled else { return }
            isCountingLines = false
            // The length can change while git counts, so the counts go into
            // the replay as it is now.
            guard let counts, var replay = self.replay else { return }
            replay.countLines(counts)
            self.replay = replay
            let map = MetroMap(replay: replay, repositoryName: repositoryName, showsHouse: showsHouse)
            phase = .ready(map)
            player.moveEnd(to: map.duration)
        }
    }

    // MARK: - Saving

    /// Waits for git to finish counting lines, so that what's saved has them.
    private func waitForLineCounts() async throws {
        guard isCountingLines else { return }
        saving = Saving(title: "Counting Lines…", progress: nil)
        while isCountingLines {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func saveVideo(colorScheme: ColorScheme) {
        guard case .ready = phase, saving == nil else { return }
        pauseIfPlaying()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(repositoryName)-\(fileSafeBranch).mp4"
        save = Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            defer { saving = nil }
            do {
                try await waitForLineCounts()
                guard case .ready(let map) = phase else { return }
                saving = Saving(title: "Saving Video…", progress: 0)
                try await ReplaySaving.writeVideo(of: map, colorScheme: colorScheme, to: url) { [weak self] progress in
                    self?.saving?.progress = progress
                }
            } catch is CancellationError {
                return
            } catch {
                showAlert("Couldn't save the video", error)
            }
        }
    }

    func saveImage(colorScheme: ColorScheme) {
        guard case .ready = phase, saving == nil else { return }
        pauseIfPlaying()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(repositoryName)-\(fileSafeBranch).png"
        save = Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            defer { saving = nil }
            do {
                try await waitForLineCounts()
                guard case .ready(let map) = phase else { return }
                try ReplaySaving.writeImage(of: map, colorScheme: colorScheme, to: url)
            } catch is CancellationError {
                return
            } catch {
                showAlert("Couldn't save the image", error)
            }
        }
    }

    func cancelSaving() {
        save?.cancel()
    }

    private func pauseIfPlaying() {
        if player.isPlaying { player.togglePlaying() }
    }

    /// The branch's name, as part of a file's name.
    private var fileSafeBranch: String {
        branchName.replacingOccurrences(of: "/", with: "-")
    }
}

/// What a replay's window shows: the player once the replay is worked out, and
/// what's happening until then.
struct ReplayView: View {
    let model: ReplayModel
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .frame(minWidth: 520, minHeight: 340)
            .overlay { savingOverlay }
            .task { model.start(reducesMotion: reducesMotion) }
            .onDisappear { model.stop() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Working out the history of \(model.branchName)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .nothing:
            VStack(spacing: 12) {
                Text("No commits in this range").foregroundStyle(.secondary)
                rangePicker.fixedSize()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let map):
            ReplayPlayerView(picture: map, player: model.player) {
                if ReplayModel.offersHouse { houseToggle }
                rangePicker.fixedSize()
                lengthPicker.fixedSize()
                Button("Save Video…") { model.saveVideo(colorScheme: colorScheme) }
                    .keyboardShortcut("s")
                    .fixedSize()
                Button("Save Image…") { model.saveImage(colorScheme: colorScheme) }
                    .keyboardShortcut("s", modifiers: [.shift, .command])
                    .fixedSize()
            }
            .disabled(model.saving != nil)
        }
    }

    private var houseToggle: some View {
        Toggle(isOn: Binding(get: { model.showsHouse }, set: { model.showsHouse = $0 })) {
            // White on the accent color that a button that's on is filled with.
            HouseFigure(pose: .mark, color: model.showsHouse ? .white : .secondary)
                .frame(width: 18, height: 16)
        }
        .toggleStyle(.button)
        .help(model.showsHouse ? "Hide the House" : "Show the House Walking the Line")
        .accessibilityLabel("Show the house walking the line")
    }

    private var rangePicker: some View {
        Picker("Range", selection: Binding(get: { model.scope ?? .wholeHistory }, set: { model.choose($0) })) {
            ForEach(model.scopes) { Text($0.title).tag($0) }
            if !model.tags.isEmpty {
                Divider()
                ForEach(model.tags, id: \.self) { tag in
                    let scope = ReplayModel.Scope.afterTag(name: tag.name, commit: tag.commit)
                    Text(scope.title).tag(scope)
                }
            }
        }
        .labelsHidden()
        .help("Which commits to replay")
        .accessibilityLabel("Range")
    }

    private var lengthPicker: some View {
        Picker("Length", selection: Binding(get: { model.length }, set: { model.choose(length: $0) })) {
            ForEach(ReplayModel.lengths, id: \.self) { Text("\(Int($0)) s").tag($0) }
        }
        .labelsHidden()
        .help("The longest it plays at normal speed")
        .accessibilityLabel("Length")
    }

    @ViewBuilder private var savingOverlay: some View {
        if let saving = model.saving {
            VStack(spacing: 12) {
                Text(saving.title).font(.headline)
                ProgressView(value: saving.progress).frame(width: 240)
                Button("Cancel") { model.cancelSaving() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Keeps a window for each replay on screen, and comes back to the one that's
/// already open for a branch.
enum ReplayWindows {
    private final class Entry: NSObject, NSWindowDelegate {
        let key: String
        let window: NSWindow
        let model: ReplayModel

        init(key: String, window: NSWindow, model: ReplayModel) {
            self.key = key
            self.window = window
            self.model = model
        }

        func windowWillClose(_ notification: Notification) {
            model.stop()
            ReplayWindows.open[key] = nil
        }
    }

    private static var open: [String: Entry] = [:]

    static func show(_ model: ReplayModel) {
        let key = "\(model.session.location.commonDirectory)\n\(model.branchName)"
        if let entry = open[key] {
            entry.window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: ReplayView(model: model))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "History of \(model.branchName)"
        window.subtitle = model.repositoryName
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1100, height: 680))
        window.center()
        let entry = Entry(key: key, window: window, model: model)
        window.delegate = entry
        open[key] = entry
        window.makeKeyAndOrderFront(nil)
    }
}
