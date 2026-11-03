import Foundation
import GitCore
import GitRunner
import Observation
import RepositoryEngine

/// A window's way through removing a linked worktree from its sidebar
/// (decision 22). It says what would be lost and asks first, and it looks again
/// before deleting anything, because an agent may have been writing there while
/// the question was open.
@Observable
final class WorktreeRemoval {
    /// What to ask before anything is deleted.
    struct Confirmation: Equatable {
        /// The repository's git directory.
        var repository: String
        var worktree: Worktree
        var losses: WorktreeLosses
        /// Whether what would be lost changed since the user was first asked.
        var changed = false

        private var name: String {
            losses.branch.map(Ref.shortName) ?? worktree.title
        }

        var title: String { "Remove Worktree \(name)?" }

        /// Forcing it is the only way once git would refuse, so that's what the
        /// button says.
        var buttonTitle: String { losses.needsForce ? "Force Remove" : "Remove" }

        /// The button that deletes the branch too, which only shows when that
        /// would lose nothing.
        var buttonTitleDeletingBranch: String? {
            losses.mergedInto == nil ? nil : "\(buttonTitle) and Delete Branch"
        }

        var failureTitle: String { "Can't Remove Worktree \(name)" }

        var message: String {
            let folder = (worktree.path as NSString).abbreviatingWithTildeInPath
            var paragraphs: [String] = []
            if changed { paragraphs.append("What's in it changed since you were asked.") }
            if losses.folderIsMissing {
                paragraphs.append("Its folder, \(folder), is gone already, so this only makes git forget the worktree.")
            } else if losses.isEmpty {
                paragraphs.append("This deletes \(folder). Everything in it is committed, so nothing is lost.")
            } else {
                paragraphs.append("This deletes \(folder), and these can't be brought back:\n" + lossDescriptions.map { "\n• \($0)" }.joined())
            }
            if let branch = losses.branch.map(Ref.shortName) {
                if let main = losses.mergedInto {
                    paragraphs.append("The branch \(branch) stays unless you delete it too, which loses nothing, because \(main) has all of its commits.")
                } else {
                    paragraphs.append("The branch \(branch) stays, with its commits.")
                }
            }
            return paragraphs.joined(separator: "\n\n")
        }

        private var lossDescriptions: [String] {
            var descriptions: [String] = []
            if !losses.changedFiles.isEmpty {
                descriptions.append(Self.describe(losses.changedFiles, one: "file with uncommitted changes", many: "files with uncommitted changes"))
            }
            if !losses.untrackedFiles.isEmpty {
                descriptions.append(Self.describe(losses.untrackedFiles, one: "untracked file", many: "untracked files"))
            }
            if !losses.ignored.isEmpty {
                descriptions.append(Self.describe(losses.ignored, one: "ignored item", many: "ignored items"))
            }
            switch losses.detachedCommits {
            case 0: break
            case 1: descriptions.append("1 commit that only its detached HEAD has")
            case let count: descriptions.append("\(count.formatted()) commits that only its detached HEAD has")
            }
            switch losses.stoppedPull {
            case nil: break
            case .merge: descriptions.append("a merge that's partway through")
            case .rebase: descriptions.append("a rebase that's partway through")
            }
            if losses.hasSubmodules { descriptions.append("its submodules, with anything uncommitted in them") }
            return descriptions
        }

        private static func describe(_ names: [String], one: String, many: String) -> String {
            let shown = names.prefix(3).joined(separator: ", ")
            let others = names.count - min(names.count, 3)
            let count = names.count == 1 ? "1 \(one)" : "\(names.count.formatted()) \(many)"
            return "\(count): \(shown)" + (others > 0 ? " and \(others.formatted()) more" : "")
        }
    }

    struct Failure: Equatable {
        var title: String
        var message: String
    }

    /// What to ask, once yaga has looked through the worktree.
    var confirmation: Confirmation?
    /// What to tell the user when git refuses, until they've seen it.
    var failure: Failure?
    /// The latest look or removal. It isn't tied to any view, because cancelling
    /// it would stop git while it's deleting files. Others can run alongside it,
    /// because deleting a large folder takes minutes, and that shouldn't hold up
    /// removing another worktree.
    @ObservationIgnored private(set) var running: Task<Void, Never>?

    /// Looks through the worktree, and then asks.
    func start(_ worktree: Worktree, of repository: ListedRepository) {
        guard let session = repository.session else { return }
        run(failureTitle: "Can't Remove Worktree \(worktree.title)") { [self] in
            confirmation = Confirmation(
                repository: repository.path,
                worktree: worktree,
                losses: try await session.lossesFromRemoving(worktree: worktree.path)
            )
        }
    }

    /// Removes the worktree the user agreed to remove, as long as that still
    /// loses what they were told, or else asks again.
    ///
    /// - Parameter deletingBranch: Whether they chose to delete its branch too.
    func confirm(_ asked: Confirmation, deletingBranch: Bool = false, list: RepositoryList) {
        confirmation = nil
        guard let repository = list.repository(at: asked.repository), let session = repository.session else { return }
        run(failureTitle: asked.failureTitle) { [self] in
            let losses = try await session.lossesFromRemoving(worktree: asked.worktree.path)
            guard losses == asked.losses else {
                confirmation = Confirmation(repository: asked.repository, worktree: asked.worktree, losses: losses, changed: true)
                return
            }
            do {
                try await list.removeWorktree(asked.worktree.path, of: repository, force: losses.needsForce, deletingBranch: deletingBranch ? losses.branch : nil)
            } catch RepositoryListError.branchKept(let branch, let message) {
                failure = Failure(title: "Can't Delete Branch \(branch)", message: "The worktree is gone, and the branch stays.\n\n\(message)")
            }
        }
    }

    private func run(failureTitle: String, _ work: @escaping () async throws -> Void) {
        running = Task {
            do {
                try await work()
            } catch {
                failure = Failure(title: failureTitle, message: (error as? GitError)?.message ?? String(describing: error))
            }
        }
    }
}
