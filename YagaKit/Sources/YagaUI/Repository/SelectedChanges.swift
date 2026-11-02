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
    /// Goes up when the user moves through the list of files, so that the list
    /// knows to scroll to the selected file.
    private(set) var fileSteps = 0

    /// Says how many files are uncommitted, whenever they've been listed.
    @ObservationIgnored var onLoad: ((Int) -> Void)?
    /// The load in progress, which a newer one cancels.
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    @ObservationIgnored private var patience: Task<Void, any Error>?
    @ObservationIgnored private let session: RepositorySession
    @ObservationIgnored private let worktree: String

    init(session: RepositorySession, worktree: String, selectedFile: SelectedFile) {
        self.session = session
        self.worktree = worktree
        self.selectedFile = selectedFile
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

    /// Selects the file `step` places from the selected one, going through the
    /// groups in order, and stops at the ends of the list.
    func selectFile(by step: Int) {
        guard case .loaded(let changes) = files else { return }
        let all = Self.groups.flatMap { group in changes[group].map { (group, $0) } }
        let index = all.firstIndex { $0.0 == selectedFile.group && $0.1.path == selectedFile.file?.path } ?? -step
        guard all.indices.contains(index + step) else { return }
        select(all[index + step].1, in: all[index + step].0)
        fileSteps += 1
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
            files = .loaded(changes)
            onLoad?(changes.fileCount)

            if !selectingFirstFile, let group = selectedFile.group, let path = selectedFile.file?.path,
               let file = changes[group].first(where: { $0.path == path })
            {
                selectedFile.refresh(file, from: source(group, changes))
                return
            }
            let first = Self.groups.lazy.compactMap { group in changes[group].first.map { (group, $0) } }.first
            selectedFile.show(first?.1, from: first.map { source($0.0, changes) })
        } catch is CancellationError {
        } catch {
            patience?.cancel()
            files = .failed(String(describing: error))
            selectedFile.show(nil, from: nil)
        }
    }
}
