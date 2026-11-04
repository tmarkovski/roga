import Foundation
import GitCore
import GitRunner
import Observation
import RepositoryEngine

/// Deleting linked worktrees from one window's sidebar. A dialog belongs to a
/// window, so this does too, while the list knows which worktrees are on their way
/// out, which every window shows.
@Observable
final class WorktreeDeletionModel {
    /// A deletion that's waiting for someone to choose how far it goes and agree to it.
    struct Pending {
        var choice: WorktreeDeletion.Choice
        /// What's picked so far. This lives with the question rather than in the view,
        /// so that a button reads it when it's pressed: a keyboard shortcut can keep
        /// an older button's action.
        var scope: WorktreeDeletion.Scope
        var title: String
        /// The newest commits that going as far as possible loses.
        var commits: [ListedCommit]
        var repository: ListedRepository
        var list: RepositoryList

        var deletion: WorktreeDeletion { choice.deletion(for: scope) }
    }

    /// Something git refused, what it said about that, and what that leaves.
    struct Failure: Equatable {
        var title: String
        /// What's gone and what's left, once part of a deletion has happened.
        var summary: String?
        /// What ran, by its arguments after `git`.
        var command: [String]?
        var said: String
        /// What can be done about it.
        var note: String?
    }

    /// The most commits and ignored files to list.
    private static let listLimit = DialogContent.listLimit

    /// A deletion that's waiting for someone to agree to it.
    var pending: Pending?
    /// What to tell the user about something that didn't work, until they've seen it.
    var failure: Failure?
    /// The latest thing this started.
    @ObservationIgnored private(set) var running: Task<Void, Never>?

    /// Asks how far to go when there's a branch that could go with the worktree. With
    /// nothing to choose, it deletes the worktree straight away when that loses
    /// nothing, and otherwise says what it would lose and asks. A worktree that git
    /// will refuse gets git's answer.
    func askToDelete(_ worktree: Worktree, in repository: ListedRepository, list: RepositoryList) {
        guard let session = repository.session, !repository.deletingWorktrees.contains(worktree.path) else { return }
        let title = Self.title(of: worktree)
        running = Task {
            do {
                let choice = try await session.prepareToDelete(worktree: worktree.path, limit: Self.listLimit)
                if choice.asksFirst {
                    let commits = (try? await session.commits(choice.deletion(for: choice.widest).lost)) ?? []
                    pending = Pending(
                        choice: choice,
                        scope: choice.startingScope,
                        title: title,
                        commits: commits.compactMap { $0.map(ListedCommit.init) },
                        repository: repository,
                        list: list
                    )
                } else {
                    await delete(choice.deletion(for: choice.startingScope), in: repository, list: list)
                }
            } catch {
                failure = Self.refusal(of: worktree.path, error: error)
            }
        }
    }

    /// Runs the deletion that was asked about.
    func confirm() {
        guard let pending else { return }
        self.pending = nil
        running = Task { await delete(pending.deletion, in: pending.repository, list: pending.list) }
    }

    private func delete(_ deletion: WorktreeDeletion, in repository: ListedRepository, list: RepositoryList) async {
        do {
            try await list.delete(deletion, in: repository)
        } catch let stopped as WorktreeDeletion.Stopped {
            failure = Self.failure(deletion, stoppedBy: stopped)
        } catch {
            failure = Self.refusal(of: deletion.worktree, error: error)
        }
    }

    // MARK: What the dialogs say

    private static func title(of worktree: Worktree) -> String {
        guard let branch = worktree.branch.map(Ref.shortName), worktree.head != nil else {
            return "Delete the worktree \((worktree.path as NSString).lastPathComponent)?"
        }
        return "Delete the worktree for \(branch)?"
    }

    private static func refusal(of folder: String, error: any Error) -> Failure {
        Failure(
            title: "Can't delete the worktree \((folder as NSString).lastPathComponent)",
            summary: "Nothing changed.",
            command: error.gitArguments,
            said: error.dialogMessage
        )
    }

    /// What's gone and what's left, after the worktree went and something after it
    /// didn't. Each thing that's left can still be deleted from the refs panel.
    private static func failure(_ deletion: WorktreeDeletion, stoppedBy stopped: WorktreeDeletion.Stopped) -> Failure {
        switch stopped.step {
        case .branch:
            let name = deletion.branch?.shortName ?? ""
            return Failure(
                title: "Can't delete \(name)",
                summary: "The worktree is gone, but its branch \(name) isn't.",
                command: deletion.branch?.arguments,
                said: stopped.message,
                note: deletion.remoteBranch.map { "\($0.shortName) wasn't touched." }
            )
        case .remoteBranch:
            let name = deletion.remoteBranch?.shortName ?? ""
            return Failure(
                title: "Can't delete \(name)",
                summary: deletion.branch == nil ? "The worktree is gone, but \(name) isn't." : "The worktree and its branch are gone, but \(name) isn't.",
                command: deletion.remoteBranch?.arguments,
                said: stopped.message,
                note: "To try again, use Delete from Remote… in the refs panel."
            )
        }
    }
}
