import GitCore
import Observation
import RepositoryEngine

/// A worktree's uncommitted changes while their row in history is selected,
/// and what the panel shows about them. As with a commit, the files that are
/// showing stay until the new ones arrive.
@Observable
final class SelectedChanges {
    enum Files: Equatable {
        case loading
        case loaded(WorktreeChanges)
        /// git couldn't list them. The message says why.
        case failed(String)
    }

    /// The groups in the order the panel lists them.
    static let groups: [WorktreeChanges.Group] = [.conflicted, .unstaged, .untracked, .staged]

    /// Whether the row is selected.
    private(set) var isSelected = false
    private(set) var files = Files.loading
    /// The same one the selected commit uses, because they share the diff
    /// panel.
    let selectedFile: SelectedFile
    /// The same one the selected commit uses, because the panels take each
    /// other's place.
    let fileList: FileListModel
    /// Goes up when the user moves through the list of files, so that the list
    /// knows to scroll to the selected file.
    private(set) var fileSteps = 0

    /// Goes up when something asks for the keyboard to go to the list of files.
    private(set) var focusRequests = 0

    /// Says what's uncommitted, whenever the files have been listed.
    @ObservationIgnored var onLoad: ((WorktreeChanges) -> Void)?
    /// Says what git refused, with a title for saying so.
    @ObservationIgnored var onFailure: ((_ title: String, _ error: any Error) -> Void)?
    /// What's waiting to go to git, oldest first.
    @ObservationIgnored private var indexChanges: [IndexChange] = []
    /// The changes being sent to git. Only one git writes the index at a time, and
    /// nothing read in the meantime is up to date.
    @ObservationIgnored private(set) var applyingIndexChanges: Task<Void, Never>?
    /// The load in progress, which a newer one cancels.
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    @ObservationIgnored private var patience: Task<Void, any Error>?
    @ObservationIgnored private let session: RepositorySession
    @ObservationIgnored private let worktree: String

    init(session: RepositorySession, worktree: String, selectedFile: SelectedFile, fileList: FileListModel) {
        self.session = session
        self.worktree = worktree
        self.selectedFile = selectedFile
        self.fileList = fileList
    }

    /// Selects the row, and selects the first file once they're listed.
    func select() {
        guard !isSelected else { return }
        isSelected = true
        selectedFile.cancelLoading()
        startLoading(selectingFirstFile: true)
    }

    /// Deselects the row, because something else is selected.
    func deselect() {
        guard isSelected else { return }
        isSelected = false
        loading?.cancel()
        loading = nil
        patience?.cancel()
    }

    /// Lists the files again, and reads the selected file again if it's still
    /// listed. Without it, the first file is selected.
    func refresh() {
        guard isSelected else { return }
        startLoading(selectingFirstFile: false)
    }

    /// Selects one of the files.
    func select(_ file: DiffFile, in group: WorktreeChanges.Group) {
        guard case .loaded(let changes) = files else { return }
        selectedFile.show(file, from: source(group, changes))
    }

    /// Selects the file `step` places from the selected one among the rows that
    /// show, going through the groups in order, and stops at the ends of the list.
    func selectFile(by step: Int) {
        guard case .loaded(let changes) = files else { return }
        select(rows(of: changes).file(step, from: selectedFile.file?.path, in: selectedFile.group), in: changes)
    }

    /// Selects the first file among the rows that show.
    func selectFirstFile() {
        guard case .loaded(let changes) = files else { return }
        select(rows(of: changes).firstFile, in: changes)
    }

    private func select(_ row: FileRow?, in changes: WorktreeChanges) {
        guard let file = row?.file, let group = row?.group else { return }
        selectedFile.show(file, from: source(group, changes))
        fileSteps += 1
    }

    /// The rows that show of every group, in order.
    private func rows(of changes: WorktreeChanges) -> [FileRow] {
        Self.groups.flatMap { fileList.rows(of: changes[$0], in: $0) }
    }

    func askForFocus() {
        focusRequests += 1
    }

    // MARK: Staging

    /// What's loaded, if anything.
    var loaded: WorktreeChanges? {
        if case .loaded(let changes) = files { changes } else { nil }
    }

    /// Stages a file, or takes it back out if it's a staged one. Staging a conflict
    /// says it's resolved.
    func toggle(_ file: DiffFile, in group: WorktreeChanges.Group) {
        apply(group == .staged ? .unstage([file]) : .stage([file]), from: group)
    }

    /// Stages or takes back out the file selected, the way Space and the menu do.
    func toggleSelectedFile() {
        guard let file = selectedFile.file, let group = selectedFile.group else { return }
        toggle(file, in: group)
    }

    /// Stages or takes back out every file in a group that the filter leaves.
    func toggleAll(in group: WorktreeChanges.Group) {
        guard let loaded else { return }
        let files = fileList.matching(loaded[group], in: group)
        guard !files.isEmpty else { return }
        apply(group == .staged ? .unstage(files) : .stage(files), from: group)
    }

    /// Stages or takes back out every file under a folder of a group.
    func toggleFolder(_ path: String, in group: WorktreeChanges.Group) {
        guard let loaded else { return }
        let files = loaded[group].filter { $0.path.hasPrefix(path + "/") }
        guard !files.isEmpty else { return }
        apply(group == .staged ? .unstage(files) : .stage(files), from: group)
    }

    /// Moves files straight away, and sends the change to git behind that, because
    /// on a large repository, waiting for git and then for a new list after each
    /// press of Space would feel slow. A new list follows and corrects the counts.
    private func apply(_ change: IndexChange, from group: WorktreeChanges.Group) {
        guard let loaded else { return }
        let before = rows(of: loaded).filter { $0.file != nil }
        let path = selectedFile.file?.path
        let isMovingSelection = selectedFile.group == group && path.map { path in change.files.contains { $0.path == path } } == true
        let place = isMovingSelection ? before.firstIndex { $0.group == group && $0.file?.path == path } : nil

        let changed = change.applied(to: loaded)
        files = .loaded(changed)
        onLoad?(changed)
        if let place {
            // What took its place, so that going down a list is one key per file.
            let after = rows(of: changed).filter { $0.file != nil }
            if after.isEmpty {
                selectedFile.show(nil, from: nil)
            } else {
                select(after[min(place, after.count - 1)], in: changed)
            }
        }
        indexChanges.append(change)
        startApplyingIndexChanges()
    }

    private func startApplyingIndexChanges() {
        guard applyingIndexChanges == nil else { return }
        applyingIndexChanges = Task {
            while let next = takeIndexChanges() {
                do {
                    try await send(next)
                } catch is CancellationError {
                } catch {
                    // Whatever was waiting was based on this working. The new list
                    // shows how things really are.
                    indexChanges = []
                    onFailure?(next.failureTitle, error)
                }
            }
            applyingIndexChanges = nil
            refresh()
        }
    }

    /// The oldest change, along with the ones right after it of the same kind, so
    /// that several presses in a row go to one git.
    private func takeIndexChanges() -> IndexChange? {
        guard var change = indexChanges.first else { return nil }
        var taken = 1
        for next in indexChanges.dropFirst() {
            guard let merged = change.merging(next) else { break }
            change = merged
            taken += 1
        }
        indexChanges.removeFirst(taken)
        return change
    }

    private func send(_ change: IndexChange) async throws {
        switch change {
        case .stage(let files): try await session.stage(files, in: worktree)
        case .unstage(let files): try await session.unstage(files, in: worktree)
        }
    }

    private func source(_ group: WorktreeChanges.Group, _ changes: WorktreeChanges) -> PatchSource {
        .worktree(path: worktree, group: group, head: changes.head)
    }

    private func startLoading(selectingFirstFile: Bool) {
        loading?.cancel()
        patience?.cancel()
        patience = Task {
            try await Task.sleep(for: SelectedFile.patience)
            try Task.checkCancellation()
            // Looking at the files again leaves the list as it is meanwhile.
            if case .loaded = files, !selectingFirstFile { return }
            files = .loading
        }
        loading = Task { await load(selectingFirstFile: selectingFirstFile) }
    }

    private func load(selectingFirstFile: Bool) async {
        do {
            let changes = try await session.changes(in: worktree)
            try Task.checkCancellation()
            patience?.cancel()
            // It's out of date already. A new list follows once git has them all.
            guard applyingIndexChanges == nil, indexChanges.isEmpty else { return }
            files = .loaded(changes)
            onLoad?(changes)

            if !selectingFirstFile, let group = selectedFile.group, let path = selectedFile.file?.path,
               let file = changes[group].first(where: { $0.path == path })
            {
                selectedFile.refresh(file, from: source(group, changes))
                return
            }
            // A filter that leaves none of them leaves the diff panel the first
            // of all.
            let first = rows(of: changes).firstFile.flatMap { row in row.file.flatMap { file in row.group.map { ($0, file) } } }
                ?? Self.groups.lazy.compactMap { group in changes[group].first.map { (group, $0) } }.first
            selectedFile.show(first?.1, from: first.map { source($0.0, changes) })
        } catch is CancellationError {
        } catch {
            patience?.cancel()
            files = .failed(String(describing: error))
            selectedFile.show(nil, from: nil)
        }
    }
}

/// One change to a worktree's index that someone asked for.
private enum IndexChange {
    case stage([DiffFile])
    case unstage([DiffFile])

    var files: [DiffFile] {
        switch self {
        case .stage(let files), .unstage(let files): files
        }
    }

    var failureTitle: String {
        switch self {
        case .stage(let files): files.count == 1 ? "Can't stage \(files[0].name)" : "Can't stage the files"
        case .unstage(let files): files.count == 1 ? "Can't unstage \(files[0].name)" : "Can't unstage the files"
        }
    }

    /// This and the next one as one, if they're the same kind.
    func merging(_ next: IndexChange) -> IndexChange? {
        switch (self, next) {
        case (.stage(let files), .stage(let more)): .stage(files + more)
        case (.unstage(let files), .unstage(let more)): .unstage(files + more)
        default: nil
        }
    }

    func applied(to changes: WorktreeChanges) -> WorktreeChanges {
        switch self {
        case .stage(let files): changes.staging(files)
        case .unstage(let files): changes.unstaging(files)
        }
    }
}

extension WorktreeChanges {
    /// How the lists will look once git has staged these files, until git says for
    /// itself. A file with changes on both sides adds up its counts.
    func staging(_ moved: [DiffFile]) -> WorktreeChanges {
        var changes = self
        let paths = Set(moved.map(\.path))
        changes.unstaged.removeAll { paths.contains($0.path) }
        changes.untracked.removeAll { paths.contains($0.path) }
        changes.conflicted.removeAll { paths.contains($0.path) }
        for var file in moved {
            switch file.status {
            case .untracked: file.status = .added
            case .conflicted: file.status = .modified
            default: break
            }
            Self.add(file, to: &changes.staged)
        }
        changes.staged.sort { $0.path < $1.path }
        return changes
    }

    /// How the lists will look once git has taken these files back out of the
    /// index, until git says for itself.
    func unstaging(_ moved: [DiffFile]) -> WorktreeChanges {
        var changes = self
        let paths = Set(moved.map(\.path))
        changes.staged.removeAll { paths.contains($0.path) }
        for var file in moved {
            switch file.status {
            case .added, .copied:
                file.status = .untracked
                file.oldPath = nil
                changes.untracked.append(file)
            case .renamed:
                // The new path isn't tracked, and the old one is gone from the disk.
                var old = file
                old.status = .deleted
                old.path = file.oldPath ?? file.path
                old.oldPath = nil
                Self.add(old, to: &changes.unstaged)
                file.status = .untracked
                file.oldPath = nil
                changes.untracked.append(file)
            default:
                Self.add(file, to: &changes.unstaged)
            }
        }
        changes.unstaged.sort { $0.path < $1.path }
        changes.untracked.sort { $0.path < $1.path }
        return changes
    }

    private static func add(_ file: DiffFile, to list: inout [DiffFile]) {
        guard let index = list.firstIndex(where: { $0.path == file.path }) else {
            list.append(file)
            return
        }
        if let lines = file.lines, let others = list[index].lines {
            list[index].lines = DiffFile.LineCounts(added: lines.added + others.added, removed: lines.removed + others.removed)
        }
    }
}
