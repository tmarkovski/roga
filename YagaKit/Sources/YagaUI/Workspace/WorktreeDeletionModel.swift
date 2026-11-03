import Foundation
import GitCore
import GitRunner
import Observation
import RepositoryEngine

/// Deleting linked worktrees from one window's sidebar. An alert belongs to a
/// window, so this does too, while the list knows which worktrees are on their way
/// out, which every window shows.
@Observable
final class WorktreeDeletionModel {
    /// A deletion that's waiting for someone to agree to it.
    struct Pending {
        var deletion: WorktreeDeletion
        var title: String
        /// The subjects of the newest commits it loses.
        var subjects: [String]
        var repository: ListedRepository
        var list: RepositoryList
    }

    /// Something git refused, and what it said about that.
    struct Failure: Equatable {
        var title: String
        var message: String
    }

    /// The most commits and ignored files to list.
    private static let listLimit = 5

    /// A deletion that's waiting for someone to agree to it.
    var pending: Pending?
    /// What to tell the user about something that didn't work, until they've seen it.
    var failure: Failure?
    /// The latest thing this started.
    @ObservationIgnored private(set) var running: Task<Void, Never>?

    /// Deletes a worktree straight away when that loses nothing, and otherwise says
    /// what it would lose and asks. Deleting from a remote always asks, because that
    /// affects everyone who uses the remote.
    func askToDelete(_ worktree: Worktree, scope: WorktreeDeletion.Scope, in repository: ListedRepository, list: RepositoryList) {
        guard let session = repository.session, !repository.deletingWorktrees.contains(worktree.path) else { return }
        let title = Self.title(of: worktree, scope: scope)
        running = Task {
            do {
                let deletion = try await session.prepareToDelete(worktree: worktree.path, scope: scope, limit: Self.listLimit)
                if deletion.asksFirst {
                    let commits = (try? await session.commits(deletion.lost)) ?? []
                    pending = Pending(deletion: deletion, title: title, subjects: commits.compactMap { $0?.subject }, repository: repository, list: list)
                } else {
                    await delete(deletion, in: repository, list: list)
                }
            } catch {
                failure = Failure(title: Self.refusal(of: worktree.path), message: (error as? GitError)?.message ?? String(describing: error))
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
            failure = Failure(title: Self.refusal(of: deletion.worktree), message: (error as? GitError)?.message ?? String(describing: error))
        }
    }

    // MARK: What the alerts say

    private static func title(of worktree: Worktree, scope: WorktreeDeletion.Scope) -> String {
        guard let branch = worktree.branch.map(Ref.shortName), worktree.head != nil else {
            return "Delete the Worktree \((worktree.path as NSString).lastPathComponent)?"
        }
        switch scope {
        case .worktree: return "Delete the Worktree for \(branch)?"
        case .worktreeAndBranch: return "Delete \(branch) and Its Worktree?"
        case .everything: return "Delete \(branch), Its Worktree and Its Remote Branch?"
        }
    }

    private static func refusal(of folder: String) -> String {
        "Can't Delete the Worktree \((folder as NSString).lastPathComponent)"
    }

    /// What's gone and what's left, after the worktree went and something after it
    /// didn't. Each thing that's left can still be deleted from the refs panel.
    private static func failure(_ deletion: WorktreeDeletion, stoppedBy stopped: WorktreeDeletion.Stopped) -> Failure {
        switch stopped.step {
        case .branch:
            let name = deletion.branch?.shortName ?? ""
            var message = "The worktree is gone, but its branch \(name) isn't:\n\n\(stopped.message)"
            if let remote = deletion.remoteBranch?.shortName { message += "\n\n\(remote) wasn't touched." }
            return Failure(title: "Can't Delete \(name)", message: message)
        case .remoteBranch:
            let name = deletion.remoteBranch?.shortName ?? ""
            return Failure(
                title: "Can't Delete \(name)",
                message: "The worktree and its branch are gone, but \(name) isn't:\n\n\(stopped.message)\n\nTo try again, use Delete from Remote… in the refs panel."
            )
        }
    }

    /// What a deletion loses, as the vision asks of destructive operations, what
    /// stays, and the commands, since this can't be taken back from here.
    static func message(for pending: Pending) -> String {
        let deletion = pending.deletion
        var parts: [String] = []
        if case .remote(let remote, _) = deletion.remoteBranch?.place {
            parts.append("This deletes the branch on \(remote), for everyone who uses it.")
        }
        if deletion.uncommittedFiles > 0 {
            parts.append(deletion.uncommittedFiles == 1
                ? "1 uncommitted file goes with the folder, and git can't bring it back."
                : "\(deletion.uncommittedFiles.formatted()) uncommitted files go with the folder, and git can't bring them back.")
        }
        if deletion.ignoredCount > 0 {
            let others = deletion.ignoredCount - deletion.ignored.count
            let names = deletion.ignored.joined(separator: ", ")
            parts.append("Files git ignores go with it too: \(names)\(others > 0 ? " and \(others.formatted()) more" : "").")
        }
        if deletion.lostCount > 0 {
            var lost = deletion.lostCount == 1
                ? "1 commit isn't on any other branch or tag:\n"
                : "\(deletion.lostCount.formatted()) commits aren't on any other branch or tag:\n"
            lost += pending.subjects.map { "\n• \($0)" }.joined()
            if deletion.lostCount > pending.subjects.count { lost += "\n• and \((deletion.lostCount - pending.subjects.count).formatted()) more" }
            parts.append(lost)
        } else if deletion.branch != nil {
            parts.append("Its commits are all on other branches or tags, so none are lost.")
        }
        if let staying = deletion.staying { parts.append("\(staying) stays.") }
        parts.append(deletion.commands.map(BranchModel.command).joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }
}
