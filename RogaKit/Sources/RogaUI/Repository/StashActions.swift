import Foundation
import GitCore
import RepositoryEngine

/// Stashing what's uncommitted, and putting back, deleting or branching from a
/// stash (decision 81). Each runs as a commit does, with nothing else alongside
/// it, and the title row says what it did. None of them ask first: stashing and
/// deleting have Undo, and putting back leaves the changes on disk, where
/// stashing them again is one click.
extension RepositoryModel {
    /// Whether the worktree's changes can be stashed now: there are some, and
    /// nothing is running or stuck partway, since git can't stash a conflict.
    var canStash: Bool {
        hasWorkingTreeRow && !branch.isBusy && branch.unfinished == nil
    }

    /// Stashes everything that's uncommitted, staged and untracked files
    /// included, and shows the new stash in the panels, so that it's clear what
    /// went in. It's named after its files, and the title row has Undo.
    func stashChanges() {
        guard canStash else { return }
        branch.run(nil, failure: "Can't stash the changes", changesNothing: true) { [weak self, session, worktree] in
            let paths = Stashes.paths(of: try await session.status(in: worktree))
            guard !paths.isEmpty,
                  let stash = try await session.stashChanges(message: Stashes.message(for: paths), in: worktree),
                  let self else { return nil }
            await showNewStash(stash)
            branch.undoFinished = BranchModel.FinishedUndo(help: "Undo Stash") { [weak self] in
                self?.putBack(stash, named: "the stash", keeping: false, isUndo: true)
            }
            return paths.count == 1 ? "Stashed 1 file" : "Stashed \(paths.count.formatted()) files"
        }
    }

    /// Puts a stash back, from its menu or its panel, and deletes it unless it's
    /// kept or git stops on a conflict.
    func putBack(_ stash: StashDetails, keeping: Bool = false) {
        putBack(stash.commit, named: stash.name, keeping: keeping, isUndo: false)
    }

    /// Deletes a stash without asking, because git keeps its commit and Undo in
    /// the title row lists it again.
    func delete(_ stash: StashDetails) {
        branch.run(nil, failure: "Can't delete \(stash.name)", changesNothing: true) { [weak self, session, worktree] in
            let message = try await session.drop(stash: stash.commit, in: worktree)
            guard let self else { return nil }
            if selectedCommit.stash?.commit == stash.commit { leaveDeletedStash() }
            branch.undoFinished = BranchModel.FinishedUndo(help: "Restore Deleted Stash") { [weak self] in
                self?.restore(stash.commit, message: message)
            }
            return "Deleted “\(BranchModel.shortened(stash.rowTitle))”"
        }
    }

    private func putBack(_ commit: ObjectID, named name: String, keeping: Bool, isUndo: Bool) {
        branch.run(nil, failure: isUndo ? "Can't restore stashed changes" : "Can't apply \(name)") { [weak self, session, worktree] in
            let outcome = try await session.putBack(stash: commit, keeping: keeping, in: worktree)
            guard let self else { return nil }
            switch outcome {
            case .back(let files, let unstaged):
                selectChangesOnceTheyShow()
                var words = isUndo ? "Stashed changes restored" : files == 1 ? "Restored 1 file from stash" : "Restored \(files.formatted()) files from stash"
                if keeping { words += " · stash retained" }
                if unstaged { words += " · staging could not be restored" }
                return words
            case .conflicted(let files, let indexBefore, let ran):
                branch.stashConflict = BranchModel.StashConflict(stash: commit, name: name, files: files, indexBefore: indexBefore, ran: ran, keeping: keeping)
                return nil
            }
        }
    }

    private func restore(_ commit: ObjectID, message: String) {
        branch.run(nil, failure: "Can't restore deleted stash", changesNothing: true) { [session, worktree] in
            try await session.restore(stash: commit, message: message, in: worktree)
            return "Restored stash to the top of the list"
        }
    }

    /// Shows a stash that was just made, before the refs panel has read it again.
    private func showNewStash(_ commit: ObjectID) async {
        let subject = (try? await session.commits([commit]))?.first??.subject ?? ""
        select(stash: StashDetails(position: 0, commit: commit, date: Int64(Date().timeIntervalSince1970), message: subject))
    }

    /// Selects something else once the stash on show is deleted: the row for
    /// uncommitted changes, or else the commit `HEAD` is on.
    private func leaveDeletedStash() {
        if hasWorkingTreeRow {
            selectRow(0)
        } else if let head = history?.refs.head {
            select(commit: head)
        }
    }
}
