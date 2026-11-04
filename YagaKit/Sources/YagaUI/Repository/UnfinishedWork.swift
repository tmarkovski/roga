import Foundation
import GitCore

/// What a worktree is stuck partway through, whoever started it: yaga, the
/// command line or an agent (decision 28).
struct UnfinishedWork: Equatable {
    /// The merge or rebase, or nil for conflicts from something else, such as
    /// `git stash pop`, which has nothing to abort.
    var work: StoppedWork?
    /// How many files have conflicts.
    var conflicts: Int

    /// Nil when nothing is unfinished.
    init?(work: StoppedWork?, conflicts: Int) {
        guard work != nil || conflicts > 0 else { return nil }
        self.work = work
        self.conflicts = conflicts
    }

    var hasConflicts: Bool { conflicts > 0 }

    /// What's underway, as in `Rebasing main`, when it's a merge or a rebase.
    var verb: String? {
        switch work {
        case .merge: "Merging"
        case .rebase(let branch?): "Rebasing \(Ref.shortName(branch))"
        case .rebase(nil): "Rebasing"
        case nil: nil
        }
    }

    /// What the title row says, as in `Merging · 2 conflicts`.
    var title: String {
        [verb, state].compactMap(\.self).joined(separator: " · ")
    }

    /// How far along it is. With no conflicts left, nothing is wrong, but it still
    /// isn't finished.
    private var state: String {
        switch (conflicts, work) {
        case (1, _): "1 conflict"
        case (0, .merge): "ready to commit"
        case (0, _): "ready to continue"
        default: "\(conflicts.formatted()) conflicts"
        }
    }
}

extension StoppedWork {
    /// What a menu calls aborting it.
    var abortTitle: String {
        switch self {
        case .merge: "Abort Merge…"
        case .rebase: "Abort Rebase…"
        }
    }

    /// What the title row says once it's been aborted.
    var abortedNote: String {
        switch self {
        case .merge: "Aborted the merge"
        case .rebase: "Aborted the rebase"
        }
    }
}
