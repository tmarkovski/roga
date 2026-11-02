import DiffUI
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
        let content: Content
    }

    /// How long what's showing stays before the panel says the next file is
    /// loading.
    static let patience = Duration.milliseconds(150)

    /// The file selected in the list.
    private(set) var file: DiffFile?
    /// What the panel shows, which is an earlier file while the selected one
    /// loads.
    private(set) var shown: Shown?
    private(set) var isWaiting = false
    /// Goes up when the user asks to find text in the diff, so that the text
    /// view knows to show its find bar.
    private(set) var findRequests = 0

    /// The load for the selected file, which selecting another one cancels.
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    /// What says the file is taking a while. It stops as soon as another file
    /// is selected, because a cancelled load can take a while to finish, and
    /// the next file may already be showing when this would go off.
    @ObservationIgnored private var patience: Task<Void, any Error>?
    @ObservationIgnored private let session: RepositorySession

    init(session: RepositorySession) {
        self.session = session
    }

    /// Selects a file of a commit, or none, and loads its patch.
    func show(_ file: DiffFile?, in commit: ObjectID?) {
        cancelLoading()
        self.file = file
        guard let file, let commit else {
            shown = nil
            isWaiting = false
            return
        }
        if let note = Self.note(for: file) {
            shown = Shown(file: file, content: .note(note))
            isWaiting = false
            return
        }
        patience = Task {
            try await Task.sleep(for: Self.patience)
            isWaiting = true
        }
        loading = Task { await load(file, in: commit) }
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

    func find() {
        findRequests += 1
    }

    /// Whether there's text to find something in.
    var canFind: Bool {
        if case .patch = shown?.content { true } else { false }
    }

    /// What to say about a file instead of comparing it, when it's known from
    /// the list of files that it has no lines to compare.
    static func note(for file: DiffFile) -> String? {
        guard let lines = file.lines else { return "This is a binary file, so there are no lines to compare." }
        guard lines.added == 0, lines.removed == 0 else { return nil }
        switch file.status {
        case .added: return "This file was added, and it's empty."
        case .deleted: return "This file was deleted, and it was empty."
        case .renamed: return "This file moved, and its contents stayed the same."
        case .copied: return "This file is a copy, and its contents are the same."
        default: return file.oldMode != file.newMode ? "Only this file's mode changed." : nil
        }
    }

    private func load(_ file: DiffFile, in commit: ObjectID) async {
        do {
            let patch = try await session.patch(of: file, in: commit)
            try Task.checkCancellation()
            let document = await DiffTextBuilder.document(for: patch)
            try Task.checkCancellation()
            finishLoading(Shown(file: file, content: .patch(document)))
        } catch is CancellationError {
        } catch {
            finishLoading(Shown(file: file, content: .failed(String(describing: error))))
        }
    }

    private func finishLoading(_ shown: Shown) {
        patience?.cancel()
        self.shown = shown
        isWaiting = false
    }
}
