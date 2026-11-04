import GitCore
import RepositoryEngine
import SwiftUI

/// What a worktree's window is asking or saying, of which it shows one at a time.
enum RepositoryDialog: Identifiable {
    case message(DialogContent)
    case pull(PullChoice, dismiss: () -> Void)
    case branchChoice(BranchModel.BranchChoice, dismiss: () -> Void)

    var id: String {
        switch self {
        case .message(let content): content.id
        case .pull: "pull"
        case .branchChoice: "branchChoice"
        }
    }

    func dismiss() {
        switch self {
        case .message(let content): content.dismiss()
        case .pull(_, let dismiss), .branchChoice(_, let dismiss): dismiss()
        }
    }
}

/// Shows whatever a worktree has to ask or say. One sheet shows all of them, so
/// that two can't get in each other's way: the second waits for the first.
struct RepositoryDialogs: ViewModifier {
    let model: RepositoryModel

    func body(content: Content) -> some View {
        let dialog = model.dialog
        content.sheet(item: Binding {
            dialog
        } set: { newValue in
            if newValue == nil { dialog?.dismiss() }
        }) { dialog in
            switch dialog {
            case .message(let content):
                DialogSheet(content: content)
            case .pull(let choice, _):
                PullChoiceSheet(asked: choice, branch: model.branch)
            case .branchChoice(let choice, _):
                BranchChoiceSheet(asked: choice, branch: model.branch)
            }
        }
    }
}

/// Asks whether to delete a branch, the remote branch it tracks or both. It reads the
/// choice in its own body, so that the switches show what's picked.
private struct BranchChoiceSheet: View {
    /// The question as it was asked, for while the sheet closes and it's gone.
    let asked: BranchModel.BranchChoice
    let branch: BranchModel

    var body: some View {
        DialogSheet(content: branch.dialog(for: branch.branchChoice ?? asked))
    }
}

extension RepositoryModel {
    /// What to ask or say now, if anything.
    var dialog: RepositoryDialog? {
        if let checkoutFailure { return .message(dialog(for: checkoutFailure)) }
        return branch.dialog
    }

    private func dialog(for failure: CheckoutFailure) -> DialogContent {
        .refusal(
            id: "checkout",
            title: "Can't check out \(failure.branch)",
            summary: failure.command == nil ? nil : "Nothing changed. What git said is below.",
            command: failure.command,
            said: failure.message
        ) { [weak self] in
            self?.checkoutFailure = nil
        }
    }
}

extension BranchModel {
    /// What to ask or say about the branch now, if anything.
    var dialog: RepositoryDialog? {
        if let failure { return .message(dialog(for: failure)) }
        if let conflict { return .message(dialog(for: conflict)) }
        if let pullChoice {
            return .pull(pullChoice) { [weak self] in self?.pullChoice = nil }
        }
        if let pendingAbort { return .message(dialog(forAborting: pendingAbort)) }
        if let forcePush { return .message(dialog(for: forcePush)) }
        if let pendingDeletion { return .message(dialog(for: pendingDeletion)) }
        if let branchChoice {
            return .branchChoice(branchChoice) { [weak self] in self?.branchChoice = nil }
        }
        return nil
    }

    private func dialog(for failure: Failure) -> DialogContent {
        let summary: DialogText? = failure.summary ?? (failure.command == nil
            ? nil
            : failure.changedNothing ? "Nothing changed. What git said is below." : "What git said is below.")
        return .refusal(
            id: "failure",
            title: failure.title,
            summary: summary,
            command: failure.command,
            said: failure.message
        ) { [weak self] in
            self?.failure = nil
        }
    }

    /// Which files a pull stopped on, and what can be done about them.
    private func dialog(for conflict: Conflict) -> DialogContent {
        // A rebase that stopped has detached `HEAD`, so only it can name the branch.
        let what: String
        let name: String?
        switch conflict.pull {
        case .merge:
            what = "merge"
            name = status.map { Ref.shortName($0.branch) }
        case .rebase(let branch):
            what = "rebase"
            name = branch.map(Ref.shortName) ?? status.map { Ref.shortName($0.branch) }
        }
        let subject: DialogText = name.map { "\(code: $0)" } ?? "The worktree"
        let files = conflict.files.count == 1 ? "1 file" : "\(conflict.files.count.formatted()) files"
        let inConflict: DialogText = conflict.files.isEmpty
            ? "is partway through a \(what)."
            : "is partway through a \(what), with \(files) in conflict."
        var rows = conflict.files.prefix(DialogContent.listLimit).map(DialogRow.name)
        if conflict.files.count > DialogContent.listLimit {
            rows.append(.more("and \((conflict.files.count - DialogContent.listLimit).formatted()) more"))
        }
        var terminal: [TerminalLine] = []
        if let ran = conflict.ran { terminal += [.ran(ran), .gap] }
        terminal += [.comment("Undo the pull runs"), .command(conflict.pull.abortArguments)]
        let leave = { [weak self] in self?.conflict = nil; return () }
        return DialogContent(
            id: "conflict",
            title: "The pull stopped on a conflict",
            message: .sentences([subject, inConflict, "yaga can't resolve conflicts yet, so you can undo the pull, or leave the worktree as it is and finish from the command line."]),
            cards: rows.isEmpty ? [] : [rows],
            terminal: terminal,
            buttons: [
                DialogButton(title: "Leave it", kind: .secondary, action: leave),
                DialogButton(title: "Undo the pull", kind: .primary) { [weak self] in self?.undoPull() },
            ],
            dismiss: leave
        )
    }

    /// What aborting loses, as the vision asks of destructive operations, and the
    /// command.
    private func dialog(forAborting work: StoppedWork) -> DialogContent {
        let what = switch work {
        case .merge: "merge"
        case .rebase: "rebase"
        }
        let cancel = { [weak self] in self?.pendingAbort = nil; return () }
        return DialogContent(
            id: "abort",
            title: "Abort the \(what)?",
            message: "This goes back to before the \(what), and any conflicts you've resolved are lost.",
            terminal: [.command(work.abortArguments)],
            buttons: [
                .cancel(cancel),
                .init(title: "Abort \(what)", kind: .destructive) { [weak self] in self?.confirmAbort() },
            ],
            dismiss: cancel
        )
    }

    /// What a force push overwrites, as the vision asks of destructive operations.
    private func dialog(for push: ForcePush) -> DialogContent {
        let cancel = { [weak self] in self?.forcePush = nil; return () }
        let message: DialogText
        let note: DialogText
        if push.count > 0 {
            let commits = push.count == 1 ? "1 commit" : "\(push.count.formatted()) commits"
            message = "This overwrites \(commits) on \(code: push.upstream), and your branch takes \(push.count == 1 ? "its place" : "their place")."
            note = "git refuses if \(code: push.upstream) has commits that \(code: push.branch) never had."
        } else {
            message = "This replaces \(code: push.upstream) with \(code: push.branch). It has no commits that \(code: push.branch) doesn't, so none are lost."
            note = "git refuses if \(code: push.upstream) has moved since your branch last had it."
        }
        let rows = DialogContent.commitRows(push.commits, total: push.count)
        return DialogContent(
            id: "forcePush",
            title: "Force push \(push.branch)?",
            message: message,
            cards: rows.isEmpty ? [] : [rows],
            note: note,
            terminal: [.command(Push.forceWithLease.arguments)],
            buttons: [
                .cancel(cancel),
                .init(title: "Force push", kind: .destructive) { [weak self] in self?.confirmForcePush() },
            ],
            dismiss: cancel
        )
    }

    /// What a deletion loses, as the vision asks of destructive operations, and the
    /// command, since it can't be taken back from here.
    private func dialog(for pending: PendingDeletion) -> DialogContent {
        let deletion = pending.deletion
        let cancel = { [weak self] in self?.pendingDeletion = nil; return () }
        var sentences: [DialogText] = []
        let title: String
        if case .remote(let remote, let branch) = deletion.place {
            title = "Delete \(branch) from \(remote)?"
            sentences.append("This deletes the branch on \(code: remote), for everyone who uses it.")
        } else {
            title = "Delete \(deletion.shortName)?"
        }
        switch deletion.lostCount {
        case 0: sentences.append("Its commits are all on other branches or tags, so none are lost.")
        case 1: sentences.append("1 commit isn't on any other branch or tag, so it goes too.")
        default: sentences.append("\(deletion.lostCount.formatted()) commits aren't on any other branch or tag, so they go too.")
        }
        let rows = DialogContent.commitRows(pending.commits, total: deletion.lostCount)
        return DialogContent(
            id: "deletion",
            title: title,
            message: .sentences(sentences),
            cards: rows.isEmpty ? [] : [rows],
            terminal: [.command(deletion.arguments)],
            buttons: [
                .cancel(cancel),
                .init(title: "Delete", kind: .destructive) { [weak self] in self?.confirmDeletion() },
            ],
            dismiss: cancel
        )
    }

    /// Asks which of a branch and the remote branch it tracks should go. Everything
    /// stays where it is while the switches flip, because a sheet can't change size.
    func dialog(for choice: BranchChoice) -> DialogContent {
        let cancel = { [weak self] in self?.branchChoice = nil; return () }
        let deletion = choice.deletion
        let commits = DialogContent.commitRows(
            choice.commits,
            total: deletion.lostCount,
            losing: choice.lostCount,
            stayingOn: choice.deletesBranch ? deletion.upstream.shortName : deletion.branch.shortName
        )
        // Each switch that's off leaves a line for its command.
        var terminal = choice.deletions.map { TerminalLine.command($0.arguments) }
        terminal += Array(repeating: .blank, count: 2 - terminal.count)
        return DialogContent(
            id: "branchChoice",
            title: "Delete \(deletion.branch.shortName)?",
            switches: [
                DialogSwitch(
                    title: "\(code: deletion.branch.shortName)",
                    detail: .ofDeletingBranch(losing: deletion.branch.lostCount, losingWithItsRemoteBranch: deletion.lostCount, remoteBranch: deletion.upstream),
                    isOn: choice.deletesBranch,
                    key: "b",
                    help: "Delete \(deletion.branch.shortName)"
                ) { [weak self] in
                    self?.branchChoice?.deletesBranch.toggle()
                },
                DialogSwitch(
                    title: "\(code: deletion.upstream.shortName)",
                    detail: .ofDeletingRemoteBranch(deletion.upstream),
                    isOn: choice.deletesUpstream,
                    key: "r",
                    help: "Delete \(deletion.upstream.shortName)"
                ) { [weak self] in
                    self?.branchChoice?.deletesUpstream.toggle()
                },
            ],
            cardsAfterSwitches: commits.isEmpty ? [] : [commits],
            terminal: terminal,
            buttons: [
                .cancel(cancel),
                .init(title: "Delete", kind: choice.isDestructive ? .destructive : .primary, isEnabled: !choice.deletions.isEmpty) { [weak self] in
                    self?.confirmBranchChoice()
                },
            ],
            dismiss: cancel
        )
    }

    /// Asks whether to rebase or merge. The command and the button follow what's
    /// picked, and remembering it adds the line that writes to the git config.
    func dialog(for choice: PullChoice) -> DialogContent {
        let cancel = { [weak self] in self?.pullChoice = nil; return () }
        let theirs = choice.behind == 1 ? "1 commit" : "\(choice.behind.formatted()) commits"
        // Remembering adds a line, and the sheet has to have room for it.
        var terminal: [TerminalLine] = [.command(choice.pick.arguments), .blank]
        if choice.remembers, let remember = choice.pick.rememberArguments {
            terminal = [.command(remember), .command(choice.pick.arguments)]
        }
        return DialogContent(
            id: "pull",
            title: "Pull \(theirs) into \(choice.branch)",
            message: "\(code: choice.branch) and \(code: choice.upstream) have moved apart. \(code: choice.upstream) has \(theirs) that \(code: choice.branch) doesn't, and \(code: choice.branch) has \(choice.ahead.formatted()) of its own.",
            terminal: terminal,
            buttons: [
                .cancel(cancel),
                .init(title: choice.pick == .rebase ? "Rebase" : "Merge", kind: .primary) { [weak self] in
                    self?.confirmPull()
                },
            ],
            dismiss: cancel
        )
    }
}

extension WorktreeDeletionModel {
    /// What to ask or say now, if anything.
    var dialog: DialogContent? {
        if let failure {
            return .refusal(
                id: "worktreeFailure",
                title: failure.title,
                summary: failure.summary.map { DialogText(stringLiteral: $0) },
                command: failure.command,
                said: failure.said,
                note: failure.note.map { DialogText(stringLiteral: $0) }
            ) { [weak self] in
                self?.failure = nil
            }
        }
        return pending.map(dialog)
    }

    /// What's lost whatever anyone chooses, how far to go, what that loses, and the
    /// commands, since this can't be taken back from here. Everything stays where it
    /// is while the switches flip, because a sheet can't change size.
    func dialog(for pending: Pending) -> DialogContent {
        let choice = pending.choice
        let deletion = pending.deletion
        let cancel = { [weak self] in self?.pending = nil; return () }

        var facts: [DialogRow] = []
        if deletion.uncommittedFiles > 0 {
            facts.append(deletion.uncommittedFiles == 1
                ? .fact("1 uncommitted file", "goes with the folder")
                : .fact("\(deletion.uncommittedFiles.formatted()) uncommitted files", "go with the folder"))
        }
        if deletion.ignoredCount > 0 {
            let others = deletion.ignoredCount - deletion.ignored.count
            let names = deletion.ignored.joined(separator: ", ")
            facts.append(.fact("Files git ignores", names + (others > 0 ? " and \(others.formatted()) more" : "")))
        }
        // The words above the card only speak for what's certainly lost.
        let losesSomething = !facts.isEmpty
        if !deletion.submodules.isEmpty {
            let others = deletion.submoduleCount - deletion.submodules.count
            let names = deletion.submodules.joined(separator: ", ")
            facts.append(.fact(deletion.submoduleCount == 1 ? "Submodule" : "Submodules", names + (others > 0 ? " and \(others.formatted()) more" : "")))
        }

        var sentences: [DialogText] = []
        if deletion.hasSubmodules {
            sentences.append("Git only removes a worktree with submodules when it's forced. Nothing has looked inside them, so anything that's only there goes too.")
        }
        if losesSomething { sentences.append("These can't be brought back:") }

        var switches: [DialogSwitch] = []
        if let branch = choice.branch {
            switches.append(DialogSwitch(
                title: "Also delete \(code: branch.shortName)",
                detail: .ofDeletingBranch(
                    losing: choice.deletion(for: .worktreeAndBranch).lostCount,
                    losingWithItsRemoteBranch: choice.deletion(for: .everything).lostCount,
                    remoteBranch: choice.remoteBranch
                ),
                isOn: pending.scope.deletesBranch,
                key: "b",
                help: "Also delete \(branch.shortName)"
            ) { [weak self] in
                self?.pending?.scope.deletesBranch.toggle()
            })
        }
        if let remoteBranch = choice.remoteBranch {
            switches.append(DialogSwitch(
                title: "Also delete \(code: remoteBranch.shortName)",
                detail: .ofDeletingRemoteBranch(remoteBranch),
                isOn: pending.scope.deletesRemoteBranch,
                key: "r",
                help: "Also delete \(remoteBranch.shortName)"
            ) { [weak self] in
                self?.pending?.scope.deletesRemoteBranch.toggle()
            })
        }

        let commits = DialogContent.commitRows(
            pending.commits,
            total: choice.deletion(for: choice.widest).lostCount,
            losing: deletion.lostCount,
            stayingOn: pending.scope.deletesBranch ? choice.remoteBranch?.shortName : choice.branch?.shortName
        )
        // Each switch that's off leaves a line for its command.
        var terminal = deletion.commands.map(TerminalLine.command)
        terminal += Array(repeating: .blank, count: choice.mostCommands - terminal.count)
        return DialogContent(
            id: "worktreeDeletion",
            title: pending.title,
            message: .sentences(sentences),
            cards: facts.isEmpty ? [] : [facts],
            switches: switches,
            cardsAfterSwitches: commits.isEmpty ? [] : [commits],
            terminal: terminal,
            buttons: [
                .cancel(cancel),
                .init(title: deletion.hasSubmodules ? "Delete anyway" : "Delete", kind: deletion.asksFirst ? .destructive : .primary) { [weak self] in self?.confirm() },
            ],
            dismiss: cancel
        )
    }
}

extension DialogText {
    /// What a switch for deleting a branch says, which is true whatever the other
    /// switch says.
    ///
    /// - Parameters:
    ///   - losing: How many commits go if only the branch does.
    ///   - losingWithItsRemoteBranch: How many go if its remote branch does too.
    static func ofDeletingBranch(losing: Int, losingWithItsRemoteBranch: Int, remoteBranch: BranchDeletion?) -> DialogText {
        if losing == 1 { return "1 commit isn't on any other branch or tag." }
        if losing > 1 { return "\(losing.formatted()) commits aren't on any other branch or tag." }
        if losingWithItsRemoteBranch > 0, let remoteBranch { return "Its commits are also on \(code: remoteBranch.shortName)." }
        return "Its commits are all on other branches or tags."
    }

    /// What a switch for deleting a remote branch says.
    static func ofDeletingRemoteBranch(_ deletion: BranchDeletion) -> DialogText {
        if case .remote(let remote, _) = deletion.place {
            return "This deletes the branch on \(code: remote), for everyone who uses it."
        }
        return "Its remote isn't configured any more, so only this repository's copy goes."
    }
}
