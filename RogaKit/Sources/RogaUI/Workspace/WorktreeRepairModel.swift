import Foundation
import GitCore
import Observation
import RepositoryEngine

/// Mending a linked worktree from one window's sidebar or tabs. For one whose
/// folder moved outside git, it asks where the folder is now and mends git's
/// links to it there. For a locked one, it takes the lock off (decision 116).
/// There's nothing to agree to, because the folder was the question, mending
/// changes nothing but the links, and unlocking changes nothing in the folder,
/// so only a failure shows a dialog, with what ran and what git said
/// (decision 29).
@Observable
final class WorktreeRepairModel {
    /// What git couldn't do, until someone has seen it.
    struct Failure: Equatable {
        var title: String
        /// What ran, by its arguments after `git`.
        var command: [String]
        /// What git said, or nil when it said nothing.
        var said: String?
        /// What that means, when git didn't say.
        var summary: String?
    }

    var failure: Failure?
    /// The latest repair this started.
    @ObservationIgnored private(set) var running: Task<Void, Never>?

    /// Asks where the worktree's folder is now, starting where it was, and mends
    /// it there.
    func locate(_ worktree: Worktree, in repository: ListedRepository, list: RepositoryList, select: @escaping (WorktreeSelection) -> Void) {
        guard let folder = chooseRepositoryFolder(
            message: "Where is the worktree for \(worktree.title) now?",
            near: worktree.path
        ) else { return }
        repair(worktree, in: repository, movedTo: folder, list: list, select: select)
    }

    /// Mends the worktree in `folder`, and shows it there.
    func repair(_ worktree: Worktree, in repository: ListedRepository, movedTo folder: String, list: RepositoryList, select: @escaping (WorktreeSelection) -> Void) {
        running = Task {
            do {
                select(try await list.repair(worktree, in: repository, movedTo: folder))
            } catch {
                failure = Self.failure(repairing: worktree, movedTo: folder, error: error)
            }
        }
    }

    /// Takes the lock off the worktree, straight away.
    func unlock(_ worktree: Worktree, in repository: ListedRepository, list: RepositoryList) {
        running = Task {
            do {
                try await list.unlock(worktree, in: repository)
            } catch {
                failure = Self.failure(unlocking: worktree, error: error)
            }
        }
    }

    static func failure(unlocking worktree: Worktree, error: any Error) -> Failure {
        Failure(
            title: "Can't unlock the worktree for \(worktree.title)",
            command: error.gitArguments ?? WorktreeRepair.unlockArguments(worktree.path),
            said: error.dialogMessage,
            summary: "Nothing changed."
        )
    }

    static func failure(repairing worktree: Worktree, movedTo folder: String, error: any Error) -> Failure {
        let title = "Can't repair the worktree for \(worktree.title)"
        let command = WorktreeRepair.arguments(movedTo: folder)
        if case RepositoryListError.notTheWorktree = error {
            return Failure(
                title: title,
                command: command,
                summary: "\((folder as NSString).lastPathComponent) is another worktree, so the folder for \(worktree.title) is still missing."
            )
        }
        return Failure(title: title, command: error.gitArguments ?? command, said: error.dialogMessage, summary: "Nothing changed.")
    }

    /// What to say now, if anything.
    var dialog: DialogContent? {
        guard let failure else { return nil }
        let dismiss = { [weak self] in self?.failure = nil; return () }
        return DialogContent(
            id: "worktreeRepairFailure",
            title: failure.title,
            message: failure.summary.map { DialogText(stringLiteral: $0) },
            terminal: [.ran(failure.command)] + (failure.said.map { [.output($0)] } ?? []),
            buttons: [DialogButton(title: "OK", kind: .primary, action: dismiss)],
            dismiss: dismiss
        )
    }
}
