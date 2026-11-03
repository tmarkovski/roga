import AppKit
import GitCore
import Observation
import RepositoryEngine

/// The commit selected in history, and what the commit panel shows about it.
/// It's a commit rather than a row, so that it stays selected when history
/// loads again in another order. The previous commit's files stay until the new
/// ones arrive, because a list that emptied on every step through history would
/// flash.
@Observable
final class SelectedCommit {
    /// The files a commit changed, which take longer to load than its message.
    enum Files: Equatable {
        case loading
        case loaded([DiffFile])
        /// git couldn't list them. The message says why.
        case failed(String)
    }

    private(set) var id: ObjectID?
    /// What the selected commit says, or nil until it's been read.
    private(set) var info: CommitInfo?
    private(set) var files = Files.loading
    /// Why the commit couldn't be read.
    private(set) var problem: String?
    /// The file selected in the commit's list, and its patch.
    let selectedFile: SelectedFile
    /// What the panel lists of the commit's files.
    let fileList = FileListModel()
    /// Goes up when the user moves through the list of files, so that the list
    /// knows to scroll to the selected file. It stays where it is when a new
    /// commit selects its first file, at the top of its message.
    private(set) var fileSteps = 0

    /// The load for the selected commit, which selecting another one cancels.
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    /// What says the files are taking a while, which stops as soon as another
    /// commit is selected, as `SelectedFile`'s does.
    @ObservationIgnored private var patience: Task<Void, any Error>?
    @ObservationIgnored private let session: RepositorySession

    init(session: RepositorySession) {
        self.session = session
        selectedFile = SelectedFile(session: session)
    }

    /// Selects a commit, or none, and loads what the panel shows about it.
    ///
    /// - Parameter keepingFile: Whether to leave the diff panel as it is when
    ///   no commit is selected, because the next thing to fill it is on its way.
    func show(_ id: ObjectID?, keepingFile: Bool = false) {
        guard id != self.id else { return }
        self.id = id
        loading?.cancel()
        loading = nil
        patience?.cancel()
        selectedFile.cancelLoading()
        guard let id else {
            info = nil
            files = .loading
            problem = nil
            if !keepingFile { selectedFile.show(nil, in: nil) }
            return
        }
        loading = Task { await load(id) }
    }

    /// Selects one of the commit's files.
    func select(_ file: DiffFile) {
        selectedFile.show(file, in: id)
    }

    /// Selects the file `step` places from the selected one among the rows that
    /// show, and stops at the ends of the list.
    func selectFile(by step: Int) {
        guard case .loaded(let files) = files,
              let file = fileList.rows(of: files).file(step, from: selectedFile.file?.path, in: nil)?.file
        else { return }
        select(file)
        fileSteps += 1
    }

    /// Selects the first file among the rows that show.
    func selectFirstFile() {
        guard case .loaded(let files) = files, let file = fileList.rows(of: files).firstFile?.file else { return }
        select(file)
        fileSteps += 1
    }

    /// Copies the selected commit's full hash.
    func copyHash(to pasteboard: NSPasteboard = .general) {
        guard let id else { return }
        pasteboard.clearContents()
        pasteboard.setString(id.hex, forType: .string)
    }

    private func load(_ id: ObjectID) async {
        do {
            let commit = try await session.commits([id]).first ?? nil
            try Task.checkCancellation()
            info = commit
            problem = commit == nil ? "This commit is missing from the repository." : nil
            guard commit != nil else {
                files = .loaded([])
                selectedFile.show(nil, in: nil)
                return
            }
        } catch is CancellationError {
            return
        } catch {
            info = nil
            problem = String(describing: error)
            files = .loaded([])
            selectedFile.show(nil, in: nil)
            return
        }

        patience = Task {
            try await Task.sleep(for: SelectedFile.patience)
            try Task.checkCancellation()
            files = .loading
            selectedFile.wait()
        }
        do {
            let changed = try await session.changedFiles(in: id)
            try Task.checkCancellation()
            patience?.cancel()
            files = .loaded(changed)
            // A filter that leaves none of them leaves the diff panel its first.
            selectedFile.show(fileList.rows(of: changed).firstFile?.file ?? changed.first, in: id)
        } catch is CancellationError {
        } catch {
            patience?.cancel()
            files = .failed(String(describing: error))
            selectedFile.show(nil, in: nil)
        }
    }
}
