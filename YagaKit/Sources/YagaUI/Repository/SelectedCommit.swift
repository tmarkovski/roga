import AppKit
import GitCore
import Observation
import RepositoryEngine

/// The commit selected in history, and what the commit panel shows about it.
/// It's a commit rather than a row, so that it stays selected when history
/// loads again in another order.
@Observable
final class SelectedCommit {
    /// The files a commit changed, which take longer to load than its message.
    enum Files: Equatable {
        case loading
        case loaded([DiffFile])
        /// git couldn't list them. The message says why.
        case failed(String)
    }

    /// How long the previous commit's files stay before the panel says they're
    /// loading. They usually take a few frames, and a list that empties and
    /// fills again on every step through history would flash.
    private static let filesPatience = Duration.milliseconds(150)

    private(set) var id: ObjectID?
    /// What the selected commit says, or nil until it's been read.
    private(set) var info: CommitInfo?
    private(set) var files = Files.loading
    /// Why the commit couldn't be read.
    private(set) var problem: String?

    /// The load for the selected commit, which selecting another one cancels.
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    @ObservationIgnored private let session: RepositorySession

    init(session: RepositorySession) {
        self.session = session
    }

    /// Selects a commit, or none, and loads what the panel shows about it.
    func show(_ id: ObjectID?) {
        guard id != self.id else { return }
        self.id = id
        loading?.cancel()
        loading = nil
        guard let id else {
            info = nil
            files = .loading
            problem = nil
            return
        }
        loading = Task { await load(id) }
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
                return
            }
        } catch is CancellationError {
            return
        } catch {
            info = nil
            problem = String(describing: error)
            files = .loaded([])
            return
        }

        let patience = Task {
            try await Task.sleep(for: Self.filesPatience)
            try Task.checkCancellation()
            files = .loading
        }
        defer { patience.cancel() }
        do {
            let changed = try await session.changedFiles(in: id)
            try Task.checkCancellation()
            files = .loaded(changed)
        } catch is CancellationError {
        } catch {
            files = .failed(String(describing: error))
        }
    }
}
