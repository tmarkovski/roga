import Foundation
import GitCore

/// What a worktree is stuck partway through, whoever started it: Roga, the
/// command line or an agent (decisions 28 and 44).
struct UnfinishedWork: Equatable {
    /// The merge, rebase or revert, or nil for conflicts from something else,
    /// such as `git stash pop`, which has nothing to abort.
    var work: StoppedWork?
    /// How many files have conflicts.
    var conflicts: Int
    /// The subject of the commit being reverted, for the tooltip, when it's been
    /// read. The title row goes by the commit's short hash.
    var subject: String?

    /// Nil when nothing is unfinished.
    init?(work: StoppedWork?, conflicts: Int, subject: String? = nil) {
        guard work != nil || conflicts > 0 else { return nil }
        self.work = work
        self.conflicts = conflicts
        self.subject = subject
    }

    var hasConflicts: Bool { conflicts > 0 }

    /// What the title row's tooltip says, which adds the subject of a commit being
    /// reverted, and how to go back.
    var help: String {
        guard let work else { return title }
        var lines = [title]
        if let subject { lines.append("\u{201C}\(subject)\u{201D}") }
        lines.append("You can finish from the command line, or \(ShellCommand.text(work.abortArguments)) goes back.")
        return lines.joined(separator: "\n")
    }

    /// What's underway, as in `Rebasing main` or `Reverting 98c48e97`, when it's a
    /// merge, a rebase or a revert. A revert goes by its commit's short hash, which
    /// the sidebar can read from a file, rather than its subject, which could be
    /// as long as the title row.
    var verb: String? {
        switch work {
        case .merge: "Merging"
        case .rebase(let branch?): "Rebasing \(Ref.shortName(branch))"
        case .rebase(nil): "Rebasing"
        case .revert(let commit?): "Reverting \(commit.hex.prefix(8))"
        case .revert(nil): "Reverting"
        case nil: nil
        }
    }

    /// What the title row says, as in `Merging · 2 conflicts`.
    var title: String {
        [verb, state].compactMap(\.self).joined(separator: " · ")
    }

    /// What a sidebar row's second line says (decision 51): what's underway,
    /// which fades out where it doesn't fit, and how far along it is, whole at
    /// the line's right end. Conflicts from something else, with nothing
    /// underway, have only how far along it is, from the line's start.
    var rowParts: (words: String, end: String?) {
        guard let verb else { return (state, nil) }
        return (verb, state)
    }

    /// How far along it is. With no conflicts left, nothing is wrong, but it still
    /// isn't finished.
    var state: String {
        switch (conflicts, work) {
        case (1, _): "1 conflict"
        case (0, .merge), (0, .revert): "ready to commit"
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
        case .revert: "Abort Revert…"
        }
    }

    /// What the title row says once it's been aborted.
    var abortedNote: String {
        switch self {
        case .merge: "Aborted the merge"
        case .rebase: "Aborted the rebase"
        case .revert: "Aborted the revert"
        }
    }

    /// What it is, in a sentence, as in `the revert`.
    var noun: String {
        switch self {
        case .merge: "merge"
        case .rebase: "rebase"
        case .revert: "revert"
        }
    }

    /// Whether git has a message ready for the commit that finishes it, in
    /// `MERGE_MSG`, which the commit box starts with and can change.
    var leavesAMessage: Bool {
        switch self {
        case .merge, .revert: true
        case .rebase: false
        }
    }
}
