import AppKit
import GitCore
import Observation
import RepositoryEngine

/// What's selected in history or the refs panel, and what the commit panel shows
/// about it: one commit, several commits as one diff, a branch since it left the
/// main branch, or a stash (decision 55). It's commits rather than rows, so that
/// it stays selected when history loads again in another order. The previous
/// files stay until the new ones arrive, because a list that emptied on every
/// step through history would flash.
@Observable
final class SelectedCommit {
    /// What the panel shows.
    enum Subject: Hashable {
        case commit(ObjectID)
        /// What changed from one commit to another, shown as one diff.
        case comparison(Comparison)
        /// Commits picked in history that aren't one after another on one line,
        /// so that they don't make one diff, and how many.
        case scattered(Int)
        case stash(StashDetails)
    }

    /// Commits shown as one diff, from `from` to `to`.
    struct Comparison: Hashable {
        enum Kind: Hashable {
            /// A run of commits on one line, each the first parent of the one
            /// before it, from `oldest` up to `to`.
            case run(count: Int, oldest: ObjectID)
            /// Two commits, from the older to the newer, unless someone swapped them.
            case pair
            /// A branch's commits since it left the branch it's compared with, by
            /// their full names.
            case branch(name: String, against: String, count: Int, hasMore: Bool)
        }

        var kind: Kind
        /// The commit to compare from, or nil for nothing at all, which is the
        /// parent of a root commit, or the base of branches with nothing in common.
        var from: ObjectID?
        var to: ObjectID

        /// The same two commits the other way around.
        var swapped: Comparison? {
            guard case .pair = kind, let from else { return nil }
            return Comparison(kind: .pair, from: to, to: from)
        }
    }

    /// Files under one heading, which only a stash's have.
    struct FileGroup: Equatable {
        var group: WorktreeChanges.Group?
        var files: [DiffFile]
        /// Where their patches come from.
        var source: PatchSource
    }

    /// The files, which take longer to load than a commit's message.
    enum Files: Equatable {
        case loading
        case loaded([FileGroup])
        /// git couldn't list them. The message says why.
        case failed(String)

        /// Every file, in the order the groups list them.
        var all: [DiffFile] {
            if case .loaded(let groups) = self { groups.flatMap(\.files) } else { [] }
        }
    }

    private(set) var subject: Subject?
    /// What the commit says, or nil until it's been read. For a comparison it's
    /// the commit compared to, and for a stash, the stash's own commit.
    private(set) var info: CommitInfo?
    /// For two commits, the one compared from.
    private(set) var fromInfo: CommitInfo?
    /// For a stash, the commit `HEAD` was on when it was made.
    private(set) var stashBase: ObjectID?
    private(set) var files = Files.loading
    /// Why it couldn't be read.
    private(set) var problem: String?
    /// The file selected in the list, and its patch.
    let selectedFile: SelectedFile
    /// What the panel lists of the files.
    let fileList = FileListModel()
    /// Goes up when the user moves through the list of files, so that the list
    /// knows to scroll to the selected file. It stays where it is when a new
    /// commit selects its first file, at the top of its message.
    private(set) var fileSteps = 0

    /// The load for what's selected, which selecting something else cancels.
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    /// What says the files are taking a while, which stops as soon as another
    /// commit is selected, as `SelectedFile`'s does.
    @ObservationIgnored private var patience: Task<Void, any Error>?
    @ObservationIgnored private let session: RepositorySession

    init(session: RepositorySession) {
        self.session = session
        selectedFile = SelectedFile(session: session)
    }

    /// The commit selected, when it's one commit.
    var id: ObjectID? {
        if case .commit(let id) = subject { id } else { nil }
    }

    /// The stash selected, if one is.
    var stash: StashDetails? {
        if case .stash(let stash) = subject { stash } else { nil }
    }

    /// The comparison selected, if one is.
    var comparison: Comparison? {
        if case .comparison(let comparison) = subject { comparison } else { nil }
    }

    /// The commit whose hash Copy Commit Hash copies.
    var hashToCopy: ObjectID? {
        switch subject {
        case .commit(let id): id
        case .stash(let stash): stash.commit
        case .comparison, .scattered, nil: nil
        }
    }

    /// Selects a commit, or none, and loads what the panel shows about it.
    ///
    /// - Parameter keepingFile: Whether to leave the diff panel as it is when
    ///   no commit is selected, because the next thing to fill it is on its way.
    func show(_ id: ObjectID?, keepingFile: Bool = false) {
        show(subject: id.map(Subject.commit), keepingFile: keepingFile)
    }

    /// Selects something to show, or nothing, and loads it.
    func show(subject: Subject?, keepingFile: Bool = false) {
        guard subject != self.subject else { return }
        self.subject = subject
        loading?.cancel()
        loading = nil
        patience?.cancel()
        selectedFile.cancelLoading()
        guard let subject else {
            info = nil
            fromInfo = nil
            stashBase = nil
            files = .loading
            problem = nil
            if !keepingFile { selectedFile.show(nil, in: nil) }
            return
        }
        loading = Task { await load(subject) }
    }

    /// Selects one of the files, from the group it's in.
    func select(_ file: DiffFile, in group: WorktreeChanges.Group? = nil) {
        guard case .loaded(let groups) = files, let source = groups.first(where: { $0.group == group })?.source else { return }
        selectedFile.show(file, from: source)
    }

    /// The rows the panel shows, in order, under every heading.
    private func rows(of groups: [FileGroup]) -> [FileRow] {
        groups.flatMap { fileList.rows(of: $0.files, in: $0.group) }
    }

    /// Selects the file `step` places from the selected one among the rows that
    /// show, and stops at the ends of the list.
    func selectFile(by step: Int) {
        guard case .loaded(let groups) = files,
              let row = rows(of: groups).file(step, from: selectedFile.file?.path, in: selectedFile.group),
              let file = row.file
        else { return }
        select(file, in: row.group)
        fileSteps += 1
    }

    /// Selects the first file among the rows that show.
    func selectFirstFile() {
        guard case .loaded(let groups) = files, let row = rows(of: groups).firstFile, let file = row.file else { return }
        select(file, in: row.group)
        fileSteps += 1
    }

    /// Copies the selected commit's full hash, or the stash's.
    func copyHash(to pasteboard: NSPasteboard = .general) {
        guard let id = hashToCopy else { return }
        pasteboard.clearContents()
        pasteboard.setString(id.hex, forType: .string)
    }

    private func load(_ subject: Subject) async {
        switch subject {
        case .commit(let id):
            guard await read([id]) else { return }
            await loadFiles { [session] in
                [FileGroup(group: nil, files: try await session.changedFiles(in: id), source: .commit(id))]
            }
        case .comparison(let comparison):
            guard await read([comparison.to] + (comparison.kind == .pair ? [comparison.from].compactMap(\.self) : [])) else { return }
            await loadFiles { [session] in
                let files = try await session.changedFiles(from: comparison.from, to: comparison.to)
                return [FileGroup(group: nil, files: files, source: .commits(from: comparison.from, to: comparison.to))]
            }
        case .scattered:
            info = nil
            fromInfo = nil
            problem = nil
            files = .loaded([])
            selectedFile.show(nil, in: nil)
        case .stash(let stash):
            guard await read([stash.commit]) else { return }
            await loadFiles { [session] in
                let contents = try await session.stashContents(stash.commit)
                self.stashBase = contents.base
                return contents.parts.map { FileGroup(group: $0.group, files: $0.files, source: $0.source) }
            }
        }
    }

    /// Reads the commits the panel says something about, the first of them into
    /// `info` and the second into `fromInfo`, and returns whether to go on to the
    /// files.
    private func read(_ ids: [ObjectID]) async -> Bool {
        do {
            let commits = try await session.commits(ids)
            try Task.checkCancellation()
            info = commits.first ?? nil
            fromInfo = commits.count > 1 ? commits[1] : nil
            stashBase = nil
            problem = commits.contains(nil) ? "This commit is missing from the repository." : nil
            guard !commits.contains(nil) else {
                files = .loaded([])
                selectedFile.show(nil, in: nil)
                return false
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            info = nil
            fromInfo = nil
            problem = String(describing: error)
            files = .loaded([])
            selectedFile.show(nil, in: nil)
            return false
        }
    }

    /// Loads the files and selects the first that shows.
    private func loadFiles(_ list: @escaping () async throws -> [FileGroup]) async {
        patience = Task {
            try await Task.sleep(for: SelectedFile.patience)
            try Task.checkCancellation()
            files = .loading
            selectedFile.wait()
        }
        do {
            let groups = try await list()
            try Task.checkCancellation()
            patience?.cancel()
            files = .loaded(groups)
            // A filter that leaves none of them leaves the diff panel its first.
            if let row = rows(of: groups).firstFile, let file = row.file {
                select(file, in: row.group)
            } else if let first = groups.first(where: { !$0.files.isEmpty }) {
                selectedFile.show(first.files[0], from: first.source)
            } else {
                selectedFile.show(nil, in: nil)
            }
        } catch is CancellationError {
        } catch {
            patience?.cancel()
            files = .failed(String(describing: error))
            selectedFile.show(nil, in: nil)
        }
    }
}
