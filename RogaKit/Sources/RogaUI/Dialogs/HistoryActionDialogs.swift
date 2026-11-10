import GitCore
import RepositoryEngine
import SwiftUI

/// Moving the branch to a commit, while someone chooses how far that goes
/// (decision 65). Double-clicking a commit always keeps uncommitted changes, so this
/// is where the other ways are.
struct PendingReset: Equatable {
    var commitSwitch: CommitSwitch
    var subject: String?
    /// The newest commits it loses, if they aren't kept as changes.
    var commits: [ListedCommit]
    /// How many files have uncommitted changes.
    var uncommittedFiles: Int
    /// What's picked so far. This lives with the question rather than in the view,
    /// so that a button reads it when it's pressed.
    var mode = ResetMode.keep

    /// What can be picked. Staged and unstaged changes only mean something for going
    /// back: across a branch that has diverged, they would also undo whatever's on
    /// the other side.
    var modes: [ResetMode] {
        commitSwitch.goesBack ? [.keep, .soft, .mixed, .hard] : [.keep, .hard]
    }

    /// Picks the way `step` rows from what's picked, staying where it is at either end.
    mutating func move(by step: Int) {
        guard let index = modes.firstIndex(of: mode), modes.indices.contains(index + step) else { return }
        mode = modes[index + step]
    }

    /// Whether what's picked can't be brought back.
    var isDestructive: Bool {
        switch mode {
        case .keep: commitSwitch.lostCount > 0
        case .soft, .mixed: false
        case .hard: commitSwitch.lostCount > 0 || uncommittedFiles > 0
        }
    }

    /// Whether what's picked gives up commits, but saves what they changed.
    var isPartlyDestructive: Bool {
        (mode == .soft || mode == .mixed) && commitSwitch.lostCount > 0
    }
}

extension ResetMode {
    var title: String {
        switch self {
        case .keep: "Keep uncommitted changes"
        case .soft: "Keep the commits' changes, staged"
        case .mixed: "Keep the commits' changes, unstaged"
        case .hard: "Discard everything"
        }
    }

    var summary: String {
        switch self {
        case .keep: "The files change to match the commit, and your uncommitted changes come along."
        case .soft: "The files stay as they are, and what the commits changed comes back staged."
        case .mixed: "The files stay as they are, and what the commits changed comes back unstaged."
        case .hard: "The files and the index change to match the commit, and uncommitted changes are lost."
        }
    }
}

/// Asks how far to move the branch, with a row for each way, and shows the exact
/// command for what's picked (decision 29). The up and down arrow keys pick, and
/// Return runs it unless it can't be brought back.
struct ResetChoiceSheet: View {
    /// The question as it was asked, for while the sheet closes and it's gone.
    let asked: PendingReset
    let model: RepositoryModel

    private var choice: PendingReset { model.pendingReset ?? asked }

    var body: some View {
        DialogSheet(content: model.dialog(for: choice)) {
            VStack(spacing: 6) {
                ForEach(choice.modes, id: \.self) { mode in
                    row(mode)
                }
            }
            .background {
                // Keys with no view of their own, for moving through the rows.
                Group {
                    Button("") { model.pendingReset?.move(by: -1) }.keyboardShortcut(.upArrow, modifiers: [])
                    Button("") { model.pendingReset?.move(by: 1) }.keyboardShortcut(.downArrow, modifiers: [])
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }

    private func row(_ mode: ResetMode) -> some View {
        let isPicked = choice.mode == mode
        return Button {
            model.pendingReset?.mode = mode
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .fontWeight(.medium)
                Text(mode.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DialogColors.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isPicked ? DialogColors.surface : DialogColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if isPicked {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DialogColors.ink, lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

extension RepositoryModel {
    /// Says what moving the branch does and what it loses, with the choice of how
    /// far it goes above the buttons.
    func dialog(for pending: PendingReset) -> DialogContent {
        let commitSwitch = pending.commitSwitch
        let short = commitSwitch.shortCommit
        let cancel = { [weak self] in self?.pendingReset = nil; return () }
        var name = "HEAD"
        if case .movingBranch(let branch) = commitSwitch.way { name = Ref.shortName(branch) }

        var sentences: [DialogText] = ["\(code: name) moves to \(code: short)."]
        if !commitSwitch.goesBack {
            sentences.append("\(code: short) isn't on \(code: name)'s line, so its commits are replaced by that line's.")
        }
        if commitSwitch.lostCount > 0 {
            sentences.append(commitSwitch.lostCount == 1
                ? "1 commit isn't on a remote, another branch or a tag, so only \(code: "git reflog") finds it afterward."
                : "\(commitSwitch.lostCount.formatted()) commits aren't on a remote, another branch or a tag, so only \(code: "git reflog") finds them afterward.")
        }
        var cards: [[DialogRow]] = []
        if commitSwitch.lostCount > 0 {
            cards.append(DialogContent.commitRows(pending.commits, total: commitSwitch.lostCount))
        } else if let subject = pending.subject {
            cards.append([.commit(hash: short, subject: subject)])
        }
        var note: DialogText?
        if pending.uncommittedFiles > 0 {
            note = pending.uncommittedFiles == 1 ? "1 file has uncommitted changes." : "\(pending.uncommittedFiles.formatted()) files have uncommitted changes."
        }
        let kind: DialogButton.Kind = pending.isDestructive ? .destructive : pending.isPartlyDestructive ? .partlyDestructive : .primary
        return DialogContent(
            id: "reset",
            title: "Reset \(name) to \(short)?",
            message: .sentences(sentences),
            cards: cards,
            note: note,
            terminal: [.command(commitSwitch.resetting(pending.mode).arguments)],
            buttons: [
                .cancel(cancel),
                DialogButton(title: "Reset", kind: kind) { [weak self] in self?.confirmReset() },
            ],
            dismiss: cancel
        )
    }

    /// Says what applying a commit would do, for the commits that aren't simple
    /// enough to apply without asking.
    func dialog(for pick: CommitCherryPick) -> DialogContent {
        let short = String(pick.commit.hex.prefix(8))
        let cancel = { [weak self] in self?.pendingCherryPick = nil; return () }
        let onto = history?.refs.currentBranch.map(Ref.shortName) ?? "HEAD"
        var sentences: [DialogText] = ["This applies what \(code: short) changed to \(code: onto), as a new commit."]
        if pick.isMerge {
            sentences.append("It's a merge, so this applies what it brought in against its first parent, \(code: String(pick.parents[0].hex.prefix(8))).")
        }
        if pick.headContains {
            sentences.append("\(code: onto) already has this commit, so there may be nothing to apply.")
        }
        return DialogContent(
            id: "cherryPick",
            title: "Cherry-pick \(short) into \(onto)?",
            message: .sentences(sentences),
            cards: [[.commit(hash: short, subject: pick.subject)]],
            terminal: [.command(pick.arguments)],
            buttons: [
                .cancel(cancel),
                // A commit that's already here is probably a slip, so it takes a click.
                DialogButton(title: "Cherry-Pick", kind: .primary, pressesWithReturn: !pick.headContains) { [weak self] in
                    self?.confirmCherryPick()
                },
            ],
            dismiss: cancel
        )
    }
}

extension BranchModel {
    /// Says what merging or rebasing does, with the commits it's about and the
    /// command.
    func dialog(for pending: PendingIntegration) -> DialogContent {
        let integration = pending.integration
        let cancel = { [weak self] in self?.pendingIntegration = nil; return () }
        let here = integration.branch.map(Ref.shortName) ?? "HEAD"
        let other = Ref.shortName(integration.ref)
        let title: String
        let button: String
        var sentences: [DialogText] = []
        var note: DialogText?
        let total: Int
        switch integration.way {
        case .merge, .fastForward:
            title = "Merge \(other) into \(here)?"
            button = "Merge"
            total = integration.incomingCount
            let coming = total == 1 ? "1 commit comes" : "\(total.formatted()) commits come"
            sentences.append("\(coming) into \(code: here) from \(code: other).")
            sentences.append(integration.ownCount > 0
                ? "A merge commit joins the two lines."
                : "\(code: here) has nothing of its own, so it moves to \(code: other) with no merge commit.")
        case .rebase:
            title = "Rebase \(here) onto \(other)?"
            button = "Rebase"
            total = integration.ownCount
            let yours = total == 1 ? "1 commit" : "\(total.formatted()) commits"
            sentences.append("\(code: here) gets \(code: other)'s commits, and then \(yours) of its own go on top, with new hashes.")
            if integration.pushedCount > 0 {
                note = integration.pushedCount == 1
                    ? "1 of these is already on its upstream, so pushing afterward will need a force push."
                    : "\(integration.pushedCount.formatted()) of these are already on its upstream, so pushing afterward will need a force push."
            }
        }
        let rows = DialogContent.commitRows(pending.commits, total: total)
        return DialogContent(
            id: "integration",
            title: title,
            message: .sentences(sentences),
            cards: rows.isEmpty ? [] : [rows],
            note: note,
            terminal: [.command(integration.arguments)],
            buttons: [
                .cancel(cancel),
                DialogButton(title: button, kind: .primary) { [weak self] in self?.confirmIntegration() },
            ],
            dismiss: cancel
        )
    }
}
