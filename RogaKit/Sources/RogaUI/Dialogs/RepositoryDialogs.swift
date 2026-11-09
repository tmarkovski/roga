import AgentEngine
import GitCore
import RepositoryEngine
import SwiftUI

/// What a worktree's window is asking or saying, of which it shows one at a time.
enum RepositoryDialog: Identifiable {
    case message(DialogContent)
    case pull(PullChoice, dismiss: () -> Void)
    case branchChoice(BranchModel.BranchChoice, dismiss: () -> Void)
    case reset(PendingReset, dismiss: () -> Void)
    case addRemote(dismiss: () -> Void)
    case gitFix(DialogContent)

    var id: String {
        switch self {
        case .message(let content), .gitFix(let content): content.id
        case .pull: "pull"
        case .branchChoice: "branchChoice"
        case .reset: "reset"
        case .addRemote: "addRemote"
        }
    }

    func dismiss() {
        switch self {
        case .message(let content), .gitFix(let content): content.dismiss()
        case .pull(_, let dismiss), .branchChoice(_, let dismiss), .reset(_, let dismiss), .addRemote(let dismiss): dismiss()
        }
    }
}

/// Makes the button that asks an agent about a refusal, when there's a command to
/// ask about and an agent to ask. It's given what failed, what git said, and how to
/// close the refusal's dialog.
typealias GitFixOffer = (_ command: [String]?, _ said: String, _ close: @escaping () -> Void) -> DialogButton?

/// Shows whatever a worktree has to ask or say. One sheet shows all of them, so
/// that two can't get in each other's way: the second waits for the first.
struct RepositoryDialogs: ViewModifier {
    let model: RepositoryModel
    @Environment(AgentProvider.self) private var agents: AgentProvider?

    func body(content: Content) -> some View {
        let dialog = model.dialog(fixingWith: agents?.generation())
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
            case .reset(let choice, _):
                ResetChoiceSheet(asked: choice, model: model)
            case .addRemote:
                AddRemoteSheet(model: model)
            case .gitFix(let content):
                GitFixSheet(model: model.gitFix, shown: content)
            }
        }
    }
}

/// Asks which of the branches on a commit should go. It reads the choice in its own
/// body, so that the switches show what's picked.
private struct BranchChoiceSheet: View {
    /// The question as it was asked, for while the sheet closes and it's gone.
    let asked: BranchModel.BranchChoice
    let branch: BranchModel

    var body: some View {
        DialogSheet(content: branch.dialog(for: branch.branchChoice ?? asked))
    }
}

/// Asks for a remote's name and where it pulls from and pushes to, and shows the
/// commands as they're typed (decision 29).
private struct AddRemoteSheet: View {
    let model: RepositoryModel
    /// What's typed so far, for while the sheet closes and the draft has gone.
    @State private var shown = BranchModel.RemoteDraft()
    @FocusState private var focused: Field?

    private enum Field {
        case name, url, pushURL
    }

    private var draft: BranchModel.RemoteDraft {
        model.branch.remoteDraft ?? shown
    }

    /// One of the draft's fields. Setting it only writes, because reading the draft
    /// while it's being written is a crash.
    private func binding(_ field: WritableKeyPath<BranchModel.RemoteDraft, String>) -> Binding<String> {
        Binding {
            draft[keyPath: field]
        } set: { [branch = model.branch] text in
            branch.remoteDraft?[keyPath: field] = text
        }
    }

    var body: some View {
        DialogSheet(content: model.branch.dialog(for: draft, among: model.remoteNames)) {
            VStack(spacing: 6) {
                row("Name", prompt: "upstream", text: binding(\.name), field: .name)
                row("Pull URL", prompt: "https://github.com/owner/repository.git", text: binding(\.url), field: .url)
                row("Push URL", prompt: "Optional", text: binding(\.pushURL), field: .pushURL)
            }
        }
        .onAppear { focused = .name }
        .onChange(of: model.branch.remoteDraft) { _, new in
            if let new { shown = new }
        }
    }

    private func row(_ title: String, prompt: String, text: Binding<String>, field: Field) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .fontWeight(.medium)
                .frame(width: 64, alignment: .leading)
            TextField(title, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($focused, equals: field)
        }
        .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
        .background(DialogColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if focused == field {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DialogColors.ink, lineWidth: 1.5)
            }
        }
    }
}

extension RepositoryModel {
    /// What to ask or say now, if anything.
    var dialog: RepositoryDialog? {
        dialog(fixingWith: nil)
    }

    /// What to ask or say now, with a way to ask `setup`'s agent about a refusal
    /// when there's an agent that can be used (decision 63).
    func dialog(fixingWith setup: GenerationSetup?) -> RepositoryDialog? {
        if let content = gitFix.dialog { return .gitFix(content) }
        let fix = gitFixOffer(setup)
        if let checkoutFailure { return .message(dialog(for: checkoutFailure, offering: fix)) }
        if let pendingCommitSwitch { return .message(dialog(for: pendingCommitSwitch)) }
        if let pendingRevert { return .message(dialog(for: pendingRevert)) }
        if let pendingReset { return .reset(pendingReset) { [weak self] in self?.pendingReset = nil } }
        if let pendingCherryPick { return .message(dialog(for: pendingCherryPick)) }
        if let pendingDiscard = selectedChanges.pendingDiscard { return .message(selectedChanges.dialog(for: pendingDiscard)) }
        return branch.dialog(offering: fix)
    }

    private func gitFixOffer(_ setup: GenerationSetup?) -> GitFixOffer {
        { [weak self] command, said, close in
            guard let setup, let command else { return nil }
            return DialogButton(title: "Fix with \(setup.kind.shortName)", kind: .secondary) { [weak self] in
                close()
                self?.gitFix.start(command: command, said: said, with: setup)
            }
        }
    }

    /// What going to a commit loses, as the vision asks of destructive operations,
    /// and the ways to save something: pushing the commits first, when git would take
    /// the push, and keeping what they changed, when the branch is going back.
    func dialog(for pending: PendingCommitSwitch) -> DialogContent {
        let commitSwitch = pending.commitSwitch
        let short = commitSwitch.shortCommit
        let cancel = { [weak self] in self?.pendingCommitSwitch = nil; return () }
        // Detaching only loses commits when `HEAD` isn't on a branch to begin with.
        let holders = if case .detaching = commitSwitch.way { "a remote, a branch or a tag" } else { "a remote, another branch or a tag" }
        let lost: DialogText = commitSwitch.lostCount == 1
            ? "1 commit isn't on \(holders), so it would be lost."
            : "\(commitSwitch.lostCount.formatted()) commits aren't on \(holders), so they would be lost."
        let rows = DialogContent.commitRows(pending.commits, total: commitSwitch.lostCount)
        var notes: [DialogText] = ["\(code: "git reflog") can still find \(commitSwitch.lostCount == 1 ? "it" : "them") for a while."]
        var terminal: [TerminalLine] = [.command(commitSwitch.arguments)]
        var buttons = [DialogButton.cancel(cancel)]

        switch commitSwitch.way {
        case .detaching:
            let branch = pending.checkout?.branch
            if let branch { terminal = [.command(["switch", branch])] }
            buttons.append(DialogButton(title: "Switch anyway", kind: .destructive) { [weak self] in self?.confirmCommitSwitch() })
            return DialogContent(
                id: "commitSwitch",
                title: "Switch to \(branch ?? short)?",
                message: .sentences(["\(code: "HEAD") isn't on a branch.", lost]),
                cards: rows.isEmpty ? [] : [rows],
                note: .sentences(notes),
                terminal: terminal,
                buttons: buttons,
                dismiss: cancel
            )
        case .movingBranch(let name):
            let name = Ref.shortName(name)
            let push = branch.status?.push
            // These two skip the push, so they need a line less than the block has room for.
            let room: [TerminalLine] = push == nil ? [] : [.blank]
            buttons.append(DialogButton(title: "Reset anyway", kind: .destructive, terminal: [.command(commitSwitch.arguments)] + room) { [weak self] in
                self?.confirmCommitSwitch()
            })
            if let keeping = commitSwitch.keepingChanges {
                notes.append("Keep changes leaves everything since \(code: short) staged.")
                buttons.append(DialogButton(title: "Keep changes", kind: .partlyDestructive, terminal: [.command(keeping.arguments)] + room) { [weak self] in
                    self?.keepChangesAndConfirmCommitSwitch()
                })
            }
            if let push {
                terminal.insert(.command(push.arguments), at: 0)
                buttons.append(DialogButton(title: "Push, then reset", kind: .primary) { [weak self] in self?.pushThenConfirmCommitSwitch() })
            } else if let upstream = branch.status?.upstream.map(Ref.shortName) {
                notes.append("Pushing first isn't offered, because git would reject it: \(code: upstream) has commits that \(code: name) doesn't.")
            }
            return DialogContent(
                id: "commitSwitch",
                title: "Reset \(name) to \(short)?",
                message: .sentences(["\(code: name) moves to \(code: short).", lost]),
                cards: rows.isEmpty ? [] : [rows],
                note: .sentences(notes),
                terminal: terminal,
                buttons: buttons,
                dismiss: cancel
            )
        }
    }

    /// What reverting a commit does, and the choice between committing it straight
    /// away and leaving the reversed changes staged (decision 44). It says up front
    /// what git would otherwise refuse or do by surprise.
    func dialog(for revert: CommitRevert) -> DialogContent {
        let short = String(revert.commit.hex.prefix(8))
        let cancel = { [weak self] in self?.pendingRevert = nil; return () }
        let head: DialogText = "\(code: "HEAD")"
        let onto: DialogText = history?.refs.currentBranch.map { "\(code: Ref.shortName($0))" } ?? head

        var sentences: [DialogText] = ["This undoes what \(code: short) changed, on \(onto)."]
        if revert.isMerge {
            let first = String(revert.parents[0].hex.prefix(8))
            let others = revert.parents.dropFirst().map { String($0.hex.prefix(8)) }
            let merged: DialogText = others.count == 1 ? "\(code: others[0])" : "its other parents"
            sentences.append("It's a merge, so this keeps the side of its first parent, \(code: first), and takes out what came from \(merged). git still counts those commits as merged, so merging them again won't bring them back.")
        }
        if !revert.headContains {
            sentences.append("\(head) doesn't contain \(code: short), so git takes its changes out of whatever \(head) has. That only makes sense if they got there another way, such as a cherry-pick.")
        }
        if !revert.canCommit {
            let staged = revert.stagedCount == 1 ? "1 file is staged" : "\(revert.stagedCount.formatted()) files are staged"
            sentences.append("\(staged), and git only commits a revert when nothing is, so this adds the reversed changes to \(revert.stagedCount == 1 ? "it" : "them").")
        }

        var notes: [DialogText] = ["Leave it uncommitted stages the reversed changes, with git's message ready to commit."]
        if revert.hasCommitHooks {
            notes.append("git commits a revert without your pre-commit and commit-msg hooks, which run when you commit from the box.")
        }

        let way: CommitRevert.Way = revert.canCommit ? .committing : .leavingUncommitted
        // A commit that isn't in `HEAD` is probably a slip, so neither button takes Return.
        let takesReturn = revert.headContains
        return DialogContent(
            id: "revert",
            title: "Revert \(short)?",
            message: .sentences(sentences),
            cards: [[.commit(hash: short, subject: revert.subject)]],
            note: .sentences(notes),
            terminal: [.command(revert.arguments(way))],
            buttons: [
                .cancel(cancel),
                DialogButton(
                    title: "Leave it uncommitted",
                    kind: revert.canCommit ? .secondary : .primary,
                    pressesWithReturn: takesReturn,
                    terminal: [.command(revert.arguments(.leavingUncommitted))]
                ) { [weak self] in
                    self?.confirmRevert(.leavingUncommitted)
                },
                DialogButton(
                    title: "Commit the revert",
                    kind: revert.canCommit ? .primary : .secondary,
                    isEnabled: revert.canCommit,
                    pressesWithReturn: takesReturn,
                    terminal: [.command(revert.arguments(.committing))]
                ) { [weak self] in
                    self?.confirmRevert(.committing)
                },
            ],
            dismiss: cancel
        )
    }

    private func dialog(for failure: CheckoutFailure, offering fix: GitFixOffer) -> DialogContent {
        let close = { [weak self] in self?.checkoutFailure = nil; return () }
        return .refusal(
            id: "checkout",
            title: "Can't check out \(failure.branch)",
            summary: failure.command == nil ? nil : "Nothing changed. What git said is below.",
            command: failure.command,
            said: failure.message,
            fix: fix(failure.command, failure.message, close),
            dismiss: close
        )
    }
}

extension CommitSwitch {
    /// The commit, as history shows it.
    var shortCommit: String { String(commit.hex.prefix(8)) }

    /// What a dialog says when this doesn't work.
    var failureTitle: String {
        switch way {
        case .movingBranch(let branch): "Can't reset \(Ref.shortName(branch)) to \(shortCommit)"
        case .detaching: "Can't switch to \(shortCommit)"
        }
    }
}

extension BranchModel {
    /// What to ask or say about the branch now, if anything.
    var dialog: RepositoryDialog? {
        dialog(offering: nil)
    }

    /// The same, with a way to ask an agent about a refusal (decision 63).
    func dialog(offering fix: GitFixOffer?) -> RepositoryDialog? {
        if let failure { return .message(dialog(for: failure, offering: fix)) }
        if let conflict { return .message(dialog(for: conflict)) }
        if let putBackConflict { return .message(dialog(for: putBackConflict)) }
        if let pullChoice {
            return .pull(pullChoice) { [weak self] in self?.pullChoice = nil }
        }
        if let pendingAbort { return .message(dialog(forAborting: pendingAbort)) }
        if let forcePush { return .message(dialog(for: forcePush)) }
        if let pendingIntegration { return .message(dialog(for: pendingIntegration)) }
        if let pendingDeletion { return .message(dialog(for: pendingDeletion)) }
        if let remoteRemoval { return .message(dialog(for: remoteRemoval)) }
        if remoteDraft != nil { return .addRemote { [weak self] in self?.remoteDraft = nil } }
        if let branchChoice {
            return .branchChoice(branchChoice) { [weak self] in self?.branchChoice = nil }
        }
        return nil
    }

    private func dialog(for failure: Failure, offering fix: GitFixOffer?) -> DialogContent {
        let summary: DialogText? = failure.summary ?? (failure.command == nil
            ? nil
            : failure.changedNothing ? "Nothing changed. What git said is below." : "What git said is below.")
        let close = { [weak self] in self?.failure = nil; return () }
        return .refusal(
            id: "failure",
            title: failure.title,
            summary: summary,
            command: failure.command,
            said: failure.message,
            fix: fix?(failure.command, failure.message, close),
            dismiss: close
        )
    }

    /// Which files a pull or a revert stopped on, and what can be done about them.
    private func dialog(for conflict: Conflict) -> DialogContent {
        // A rebase that stopped has detached `HEAD`, so only it can name the branch.
        let name = switch conflict.work {
        case .rebase(let branch): branch.map(Ref.shortName) ?? status.map { Ref.shortName($0.branch) }
        case .merge, .revert, .cherryPick: status.map { Ref.shortName($0.branch) }
        }
        let what = conflict.work.noun
        let started = conflict.startedByPull ? "pull" : what
        let subject: DialogText = name.map { "\(code: $0)" } ?? "The worktree"
        let files = conflict.files.count == 1 ? "1 file" : "\(conflict.files.count.formatted()) files"
        let inConflict: DialogText = conflict.files.isEmpty
            ? "is partway through a \(what)."
            : "is partway through a \(what), with \(files) in conflict."
        var sentences = [subject, inConflict, "You can resolve them here, or undo the \(started)."]
        if conflict.stagedBefore > 0 {
            let staged = conflict.stagedBefore == 1 ? "the 1 file that was" : "the \(conflict.stagedBefore.formatted()) files that were"
            sentences.append("Undoing it also takes back \(staged) staged before.")
        }
        var undo = [conflict.work.abortArguments]
        if let aside = conflict.aside {
            sentences.append("Your uncommitted changes are in the stash \(code: aside.message). Undoing the \(started) puts them back, and so does \(code: ShellCommand.text(ChangesAside.putBackArguments)) once you've finished.")
            undo = aside.undoArguments(stopped: conflict.work) + [ChangesAside.putBackArguments]
        }
        var terminal: [TerminalLine] = []
        if let ran = conflict.ran { terminal += [.ran(ran), .gap] }
        terminal += [.comment("Undo the \(started) runs")] + undo.map(TerminalLine.command)
        let rows = Self.fileRows(conflict.files)
        let leave = { [weak self] in self?.conflict = nil; return () }
        // Resolving is usually what someone wants after a pull, and loses nothing,
        // so Return presses it, and Undo stays a click away (decision 60).
        let resolve = { [weak self] in
            self?.conflict = nil
            self?.showConflicts()
            return ()
        }
        return DialogContent(
            id: "conflict",
            title: "The \(started) stopped on a conflict",
            message: .sentences(sentences),
            cards: rows.isEmpty ? [] : [rows],
            terminal: terminal,
            buttons: [
                // Files that were staged before can't be brought back.
                DialogButton(title: "Undo the \(started)", kind: conflict.stagedBefore > 0 ? .destructive : .secondary) { [weak self] in
                    self?.undoConflict()
                },
                DialogButton(title: "Resolve", kind: .primary, action: resolve),
            ],
            dismiss: leave
        )
    }

    /// Which files came back with conflicts once uncommitted changes that were set
    /// aside for a move were put back, and what can be done about them (decision 59).
    private func dialog(for conflict: PutBackConflict) -> DialogContent {
        let aside = conflict.aside
        let noun = conflict.noun
        let branch = aside.branch.map(Ref.shortName) ?? "HEAD"
        let (did, against): (DialogText, String) = switch aside.move {
        case .pull: ("Roga pulled into \(code: branch)", "what came in")
        case .merge(let other): ("Roga merged \(code: other) into \(code: branch)", "what came in")
        case .rebase(let other): ("Roga rebased \(code: branch) onto \(code: other)", "what's there")
        case .cherryPick(let commit): ("Roga applied \(code: String(commit.hex.prefix(8))) to \(code: branch)", "what it changed")
        case .reset(let commit): ("Roga moved \(code: branch) to \(code: String(commit.hex.prefix(8)))", "what's there")
        case .detach(let commit): ("Roga switched to \(code: String(commit.hex.prefix(8)))", "what's there")
        }
        let files = conflict.files.count == 1 ? "1 file" : "\(conflict.files.count.formatted()) files"
        let sentences: [DialogText] = [
            "\(did) and put your uncommitted changes back, but in \(files) they conflict with \(against).",
            "You can resolve them here, or undo the \(noun).",
        ]
        let note: DialogText? = .sentences([
            "Undo the \(noun) goes back to \(code: String(aside.head.hex.prefix(8))) and puts your changes back as they were, with what you'd staged.",
            "Until you drop it, the stash \(code: aside.message) keeps a copy of them as they were.",
        ])
        let undo = aside.undoArguments(stopped: nil) + [ChangesAside.putBackArguments]
        let terminal: [TerminalLine] = conflict.ran.map(TerminalLine.ran) + [.gap, .comment("Undo the \(noun) runs")] + undo.map(TerminalLine.command)
        let rows = Self.fileRows(conflict.files)
        let leave = { [weak self] in self?.putBackConflict = nil; return () }
        let resolve = { [weak self] in
            self?.putBackConflict = nil
            self?.showConflicts()
            return ()
        }
        return DialogContent(
            id: "putBackConflict",
            title: "Putting your changes back stopped on a conflict",
            message: .sentences(sentences),
            cards: rows.isEmpty ? [] : [rows],
            note: note,
            terminal: terminal,
            buttons: [
                // The stash has everything that was uncommitted, so nothing is lost.
                DialogButton(title: "Undo the \(noun)", kind: .secondary) { [weak self] in
                    self?.undoPutBack()
                },
                DialogButton(title: "Resolve", kind: .primary, action: resolve),
            ],
            dismiss: leave
        )
    }

    /// Files in a card, as many as a dialog lists.
    private static func fileRows(_ files: [String]) -> [DialogRow] {
        var rows = files.prefix(DialogContent.listLimit).map(DialogRow.name)
        if files.count > DialogContent.listLimit {
            rows.append(.more("and \((files.count - DialogContent.listLimit).formatted()) more"))
        }
        return rows
    }

    /// What aborting loses, as the vision asks of destructive operations, and the
    /// command. git aborts a revert by taking everything staged back to `HEAD`,
    /// which includes anything that was staged before the revert began.
    private func dialog(forAborting work: StoppedWork) -> DialogContent {
        let what = work.noun
        let cancel = { [weak self] in self?.pendingAbort = nil; return () }
        var message: DialogText = "This goes back to before the \(what), and any conflicts you've resolved are lost."
        var cards: [[DialogRow]] = []
        var note: DialogText?
        if case .revert = work {
            message = "This takes everything that's staged back to \(code: "HEAD"), in the index and in the files, including anything that was staged before the revert. Any conflicts you've resolved are lost too."
            let staged = stagedFiles()
            if staged > 0 {
                cards = [[staged == 1 ? .fact("1 staged file", "goes back to HEAD") : .fact("\(staged.formatted()) staged files", "go back to HEAD")]]
            }
            note = "If a staged file has changed since it was staged, git refuses, and nothing changes."
        }
        return DialogContent(
            id: "abort",
            title: "Abort the \(what)?",
            message: message,
            cards: cards,
            note: note,
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

    /// What removing a remote takes with it. The remote itself doesn't change, and
    /// nothing stops someone adding it back, but which branches used it would be gone.
    func dialog(for removal: RemoteRemoval) -> DialogContent {
        let cancel = { [weak self] in self?.remoteRemoval = nil; return () }
        var sentences: [DialogText] = ["This removes \(code: removal.name) from this repository. Nothing changes on the remote itself."]
        switch removal.branchCount {
        case 0: break
        case 1: sentences.append("Its remote branch goes from here too, and adding the remote back and fetching brings it again.")
        default: sentences.append("Its \(removal.branchCount.formatted()) remote branches go from here too, and adding the remote back and fetching brings them again.")
        }
        var rows: [DialogRow] = []
        if !removal.branches.isEmpty {
            rows.append(.heading(removal.branches.count == 1 ? "This branch stops pushing and pulling there" : "These branches stop pushing and pulling there", isLost: false))
            rows += removal.branches.prefix(DialogContent.listLimit).map(DialogRow.name)
            if removal.branches.count > DialogContent.listLimit {
                rows.append(.more("and \((removal.branches.count - DialogContent.listLimit).formatted()) more"))
            }
        }
        return DialogContent(
            id: "remoteRemoval",
            title: "Remove \(removal.name)?",
            message: .sentences(sentences),
            cards: rows.isEmpty ? [] : [rows],
            terminal: [.command(RepositorySession.removeRemoteArguments(removal.name))],
            buttons: [
                .cancel(cancel),
                .init(title: "Remove", kind: .destructive) { [weak self] in self?.confirmRemoteRemoval() },
            ],
            dismiss: cancel
        )
    }

    /// What adding a remote runs, which fills in as it's typed. Its note is always
    /// there and its commands have a height of their own, because a sheet can't
    /// change size and URLs can be long.
    func dialog(for draft: RemoteDraft, among remotes: [String]) -> DialogContent {
        let cancel = { [weak self] in self?.remoteDraft = nil; return () }
        let remote = draft.remote
        let note: DialogText = switch remote.problem(among: remotes) {
        case .nameTaken: "\(code: remote.name) is already a remote."
        case .badName: "A remote's name can't have spaces or start with a hyphen."
        case .badURL: "A URL can't start with a hyphen."
        case nil: "Without a push URL, pushes go to the pull URL."
        }
        let shown = NewRemote(name: remote.name.isEmpty ? "name" : remote.name, url: remote.url.isEmpty ? "url" : remote.url, pushURL: remote.pushURL)
        let terminal = shown.commands.map(TerminalLine.command) + [.command(RepositorySession.fetchArguments(from: shown.name))]
        return DialogContent(
            id: "addRemote",
            title: "Add a remote",
            message: "This adds a remote to the repository and fetches its branches.",
            note: note,
            terminal: terminal,
            terminalHeight: Self.addRemoteCommandsHeight,
            buttons: [
                .cancel(cancel),
                .init(title: "Add remote", kind: .primary, isEnabled: remote.canBeAdded(among: remotes) && !isBusy) { [weak self] in
                    self?.addDraftedRemote(among: remotes)
                },
            ],
            dismiss: cancel
        )
    }

    /// Five lines, which is both URLs wrapped once and the fetch. Longer ones scroll.
    private static let addRemoteCommandsHeight: CGFloat = 120

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
            note: .stayingCheckedOut(pending.checkedOut),
            terminal: [.command(deletion.arguments)],
            buttons: [
                .cancel(cancel),
                // Only history's menu gets here with something that loses nothing, where
                // the same Delete… asks about everything.
                .init(title: "Delete", kind: deletion.asksFirst ? .destructive : .primary) { [weak self] in self?.confirmDeletion() },
            ],
            dismiss: cancel
        )
    }

    /// Asks which of the branches on a commit should go. Everything stays where it is
    /// while the switches flip, because a sheet can't change size.
    func dialog(for choice: BranchChoice) -> DialogContent {
        let cancel = { [weak self] in self?.branchChoice = nil; return () }
        let deletion = choice.deletion
        let commits = DialogContent.commitRows(
            choice.commits,
            total: deletion.lostCount,
            losing: choice.lostCount,
            stayingOn: deletion.branches.first { !choice.picked.contains($0.ref) }?.shortName
        )
        // Each switch that's off leaves room for its command.
        let terminal = choice.deletions.map { TerminalLine.command($0.arguments) }
            + deletion.branches.filter { !choice.picked.contains($0.ref) }.map { TerminalLine.room($0.arguments) }
        return DialogContent(
            id: "branchChoice",
            title: "Delete which branches?",
            switches: deletion.branches.enumerated().map { index, branch in
                let others = deletion.branches.filter { $0.ref != branch.ref }
                return DialogSwitch(
                    title: "\(code: branch.shortName)",
                    detail: branch.place == .local
                        ? .ofDeletingBranch(losing: 0, losingWithItsRemoteBranch: deletion.lostCount, remoteBranch: others.count == 1 ? others[0] : nil)
                        : .ofDeletingRemoteBranch(branch),
                    isOn: choice.picked.contains(branch.ref),
                    // There's any number of these, so they go by their place in the list.
                    key: index < 9 ? Character(String(index + 1)) : nil,
                    help: "Delete \(branch.shortName)"
                ) { [weak self] in
                    self?.branchChoice?.flip(branch.ref)
                }
            },
            cardsAfterSwitches: commits.isEmpty ? [] : [commits],
            note: .stayingCheckedOut(deletion.checkedOut.map(\.shortName)),
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
