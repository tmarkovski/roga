import DiffUI
import Foundation
import GitCore
import Observation
import RepositoryEngine

/// The file selected in the commit panel, and what the diff panel shows of it.
/// What's showing stays until the next file's patch is ready, because a panel
/// that emptied on every step through a list would flash.
@Observable
final class SelectedFile {
    enum Content {
        case patch(DiffDocument)
        /// The file has no lines to compare, and this says what changed.
        case note(String)
        /// git couldn't show the patch. The message says why.
        case failed(String)
    }

    struct Shown {
        let file: DiffFile
        let source: PatchSource
        let content: Content
        /// Whether this is the file that was showing already, with what it
        /// has now, so that the text should stay at the same place.
        var isUpdate = false
    }

    /// Where the text being searched for shows in a document.
    struct Matches {
        let document: DiffDocument
        let ranges: [NSRange]
        /// Which of them the search is at.
        var current: Int?
    }

    /// How long what's showing stays before the panel says the next file is
    /// loading.
    static let patience = Duration.milliseconds(150)

    /// The file selected in the list.
    private(set) var file: DiffFile?
    /// Where the selected file's changes are.
    private(set) var source: PatchSource?
    /// What the panel shows, which is an earlier file while the selected one
    /// loads.
    private(set) var shown: Shown? {
        didSet {
            if shownDocument !== matches?.document { search(scrolling: shown?.isUpdate != true) }
        }
    }
    private(set) var isWaiting = false
    /// Whether the box for finding text shows, which it doesn't until someone
    /// asks for it. It stays open from one file to the next.
    private(set) var isFindShown = false
    /// Whether a command asked for the keyboard to go to the box, which the
    /// panel does once it's showing.
    var wantsFindFocus = false
    /// The text to find in the diff.
    var findText = "" {
        didSet {
            if findText != oldValue { search() }
        }
    }
    /// Where that text shows, once it's been looked for.
    private(set) var matches: Matches?
    /// Goes up when the search moves to a match, so that the text view knows to
    /// bring it into view.
    private(set) var matchSteps = 0
    /// Goes up when the box closes, so that the text view knows to take the
    /// keyboard back.
    private(set) var findCloses = 0

    /// The load for the selected file, which selecting another one cancels.
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    /// What says the file is taking a while. It stops as soon as another file
    /// is selected, because a cancelled load can take a while to finish, and
    /// the next file may already be showing when this would go off.
    @ObservationIgnored private var patience: Task<Void, any Error>?
    /// The patch showing, for telling whether looking at the file again found
    /// anything new, and for cutting a hunk out of.
    @ObservationIgnored private(set) var shownPatch: FilePatch?
    /// The search for the latest text, which typing more cancels.
    @ObservationIgnored private(set) var searching: Task<Void, Never>?
    @ObservationIgnored private let session: RepositorySession

    init(session: RepositorySession) {
        self.session = session
    }

    /// Selects a file of a commit, or none, and loads its patch.
    func show(_ file: DiffFile?, in commit: ObjectID?) {
        show(file, from: commit.map(PatchSource.commit))
    }

    /// Selects a file, or none, and loads its patch.
    func show(_ file: DiffFile?, from source: PatchSource?) {
        cancelLoading()
        self.file = file
        self.source = source
        guard let file, let source else {
            shown = nil
            isWaiting = false
            return
        }
        if let note = Self.note(for: file) {
            shown = Shown(file: file, source: source, content: .note(note))
            shownPatch = nil
            isWaiting = false
            return
        }
        patience = Task {
            try await Task.sleep(for: Self.patience)
            // The file can arrive after the sleep ends and before this runs.
            try Task.checkCancellation()
            isWaiting = true
        }
        loading = Task { await load(file, from: source) }
    }

    /// Reads the selected file again, because it may have changed. What's
    /// showing stays, without a spinner, and it only changes if the file did.
    func refresh(_ file: DiffFile, from source: PatchSource) {
        cancelLoading()
        self.file = file
        self.source = source
        if let note = Self.note(for: file) {
            shown = Shown(file: file, source: source, content: .note(note), isUpdate: true)
            shownPatch = nil
            isWaiting = false
            return
        }
        loading = Task { await load(file, from: source, isRefresh: true) }
    }

    /// Stops loading a file, because the commit it belongs to isn't selected
    /// any more.
    func cancelLoading() {
        loading?.cancel()
        loading = nil
        patience?.cancel()
    }

    /// Says that the next file is taking a while, before it's known which one.
    func wait() {
        isWaiting = true
    }

    /// Shows the box for finding text, or goes back to it if it's showing.
    func find() {
        isFindShown = true
        wantsFindFocus = true
    }

    /// Hides the box, and stops marking what it found.
    func closeFind() {
        isFindShown = false
        findText = ""
        findCloses += 1
    }

    func toggleFind() {
        if isFindShown { closeFind() } else { find() }
    }

    func findNext() {
        step(by: 1)
    }

    func findPrevious() {
        step(by: -1)
    }

    /// Moves to another match, going around at either end.
    private func step(by step: Int) {
        guard let count = matches?.ranges.count, count > 0 else { return }
        let current = matches?.current ?? (step > 0 ? -1 : 0)
        matches?.current = (current + step + count) % count
        matchSteps += 1
    }

    /// Looks for the text in the document showing. Until that's done, the marks
    /// and the count stay as they were, so that they don't flash as someone types.
    private func search(scrolling: Bool = true) {
        searching?.cancel()
        guard !findText.isEmpty, let document = shownDocument else {
            if matches != nil { matches = nil }
            return
        }
        let query = findText
        // Typing more stays around the same place, and a new file starts over.
        let place = matches.flatMap { $0.document === document ? $0.currentRange?.location : nil } ?? 0
        searching = Task {
            let ranges = await document.matches(of: query)
            guard !Task.isCancelled else { return }
            let current = ranges.firstIndex { $0.location >= place } ?? (ranges.isEmpty ? nil : 0)
            matches = Matches(document: document, ranges: ranges, current: current)
            if scrolling { matchSteps += 1 }
        }
    }

    /// Whether there are any matches to go to.
    var hasMatches: Bool {
        matches?.ranges.isEmpty == false
    }

    /// How the search went, once it's looked.
    var matchesNote: String? {
        guard let matches else { return nil }
        guard let current = matches.current else { return "No matches" }
        return "\(current + 1) of \(matches.ranges.count)"
    }

    private var shownDocument: DiffDocument? {
        if case .patch(let document) = shown?.content { document } else { nil }
    }

    /// Whether there's text to find something in.
    var canFind: Bool {
        shownDocument != nil
    }

    /// The group of a worktree's changes or a stash's that the selected file is
    /// in, or nil when it belongs to a commit or a comparison.
    var group: WorktreeChanges.Group? {
        source?.group
    }

    /// What to say about a file instead of comparing it, when it's known from
    /// the list of files that it has no lines to compare.
    static func note(for file: DiffFile) -> String? {
        guard let lines = file.lines else { return binaryFileNote }
        guard lines.added == 0, lines.removed == 0 else { return nil }
        switch file.status {
        case .added: return "This file was added, and it's empty."
        case .deleted: return "This file was deleted, and it was empty."
        case .renamed: return "This file moved, and its contents stayed the same."
        case .copied: return "This file is a copy, and its contents are the same."
        default: return file.oldMode != file.newMode ? "Only this file's mode changed." : nil
        }
    }

    private static let binaryFileNote = "This is a binary file, so there are no lines to compare."

    /// What to say about a file whose patch turned out to have no lines, which
    /// the list of files couldn't tell, because it doesn't count an untracked
    /// file's lines and is older than the patch.
    private static func note(for patch: FilePatch, of file: DiffFile, from source: PatchSource) -> String {
        if patch.isBinary { return binaryFileNote }
        if file.status == .untracked { return "This file is empty." }
        if case .worktree = source { return "This file has no uncommitted changes any more." }
        return "This file has no lines to compare."
    }

    private func load(_ file: DiffFile, from source: PatchSource, isRefresh: Bool = false) async {
        do {
            let patch = try await session.patch(of: file, from: source)
            try Task.checkCancellation()
            if isRefresh, let shown, patch.bytes == shownPatch?.bytes {
                finishLoading(Shown(file: file, source: source, content: shown.content, isUpdate: true), patch: patch)
                return
            }
            let content: Content = if patch.lines.isEmpty {
                .note(Self.note(for: patch, of: file, from: source))
            } else {
                .patch(await DiffTextBuilder.document(for: patch))
            }
            try Task.checkCancellation()
            finishLoading(Shown(file: file, source: source, content: content, isUpdate: isRefresh), patch: patch)
        } catch is CancellationError {
        } catch {
            finishLoading(Shown(file: file, source: source, content: .failed(String(describing: error))), patch: nil)
        }
    }

    private func finishLoading(_ shown: Shown, patch: FilePatch?) {
        patience?.cancel()
        self.shown = shown
        shownPatch = patch
        isWaiting = false
    }
}

extension SelectedFile.Matches {
    /// Where the match the search is at is.
    var currentRange: NSRange? {
        current.map { ranges[$0] }
    }
}
