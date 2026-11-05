import Foundation
import GitCore

extension SelectedChanges {
    /// What discarding more than one file, or everything, comes to (decision 39).
    func dialog(for pending: PendingDiscard) -> DialogContent {
        switch pending {
        case .files(let files, let group, let place):
            dialog(discarding: files, from: group, place: place)
        case .everything(let changes):
            dialog(discardingEverything: changes)
        }
    }

    private var cancelDiscard: () -> Void {
        { [weak self] in self?.pendingDiscard = nil }
    }

    private var confirmingDiscard: () -> Void {
        { [weak self] in self?.confirmDiscard() }
    }

    /// Red is for what can't be brought back, so moving files to the Trash is ink, and
    /// Return presses it. What's in a patch only lasts until Roga quits, so that's red.
    private func dialog(discarding files: [DiffFile], from group: WorktreeChanges.Group, place: PendingDiscard.Place) -> DialogContent {
        let restored = files.filter { group.discarding($0) == .restore }.map(\.path)
        let trashed = files.filter { group.discarding($0) == .trash }
        let count = files.count.formatted()
        let which = switch place {
        case .folder(let path): "\(count) files in \(path)"
        case .heading: "\(count) \(group.title.lowercased()) files"
        case .matchingFilter: "\(count) matching files"
        }

        var rows = files.prefix(DialogContent.listLimit).map { DialogRow.name($0.path) }
        if files.count > DialogContent.listLimit {
            rows.append(.more("and \((files.count - DialogContent.listLimit).formatted()) more"))
        }

        guard !restored.isEmpty else {
            return DialogContent(
                id: "discard",
                title: "Move \(which) to the Trash?",
                message: "git has no copy of these, so they go to the Trash rather than away for good.",
                cards: [rows],
                buttons: [
                    .cancel(cancelDiscard),
                    DialogButton(title: "Move to Trash", kind: .primary, action: confirmingDiscard),
                ],
                dismiss: cancelDiscard
            )
        }

        var terminal: [TerminalLine] = [.command(["restore", "--worktree", "--"] + restored.prefix(DialogContent.listLimit))]
        if restored.count > DialogContent.listLimit {
            terminal.append(.comment("and \((restored.count - DialogContent.listLimit).formatted()) more"))
        }
        if !trashed.isEmpty {
            terminal.append(.comment(trashed.count == 1 ? "1 file goes to the Trash" : "\(trashed.count.formatted()) files go to the Trash"))
        }
        return DialogContent(
            id: "discard",
            title: "Discard \(which)?",
            message: "They go back to what's staged, or to \(code: "HEAD") if nothing is. What's staged stays.",
            cards: [rows],
            terminal: terminal,
            buttons: [
                .cancel(cancelDiscard),
                DialogButton(title: "Discard \(count) files", kind: .destructive, action: confirmingDiscard),
            ],
            dismiss: cancelDiscard
        )
    }

    private func dialog(discardingEverything changes: WorktreeChanges) -> DialogContent {
        let new = changes.staged.filter { $0.status == .added }.map(\.path)
        let tracked = Set(changes.staged.map(\.path))
            .union(changes.unstaged.filter { WorktreeChanges.Group.unstaged.discarding($0) == .restore }.map(\.path))
            .subtracting(new)
        let trashed = changes.trashedWhenDiscardingEverything
        let staying = changes.stayingWhenDiscardingEverything.map(\.path)

        var rows: [DialogRow] = []
        if !tracked.isEmpty {
            rows.append(.fact(Self.files(tracked.count, "changed"), tracked.count == 1 ? "goes back to HEAD" : "go back to HEAD"))
        }
        if !new.isEmpty {
            rows.append(.fact(Self.files(new.count, "new staged"), new.count == 1 ? "is deleted" : "are deleted"))
        }
        if !trashed.isEmpty {
            rows.append(.fact(Self.files(trashed.count, "untracked"), trashed.count == 1 ? "goes to the Trash" : "go to the Trash"))
        }

        var terminal: [TerminalLine] = []
        if !tracked.isEmpty || !new.isEmpty {
            // Before the first commit there's nothing for a stash to keep them against.
            if changes.head != nil { terminal.append(.command(["stash", "create"])) }
            terminal.append(.command(["reset", "--hard"]))
        }
        let losesSomething = !terminal.isEmpty
        if losesSomething, !trashed.isEmpty {
            terminal.append(.comment(trashed.count == 1 ? "1 file goes to the Trash" : "\(trashed.count.formatted()) files go to the Trash"))
        }

        var note: DialogText?
        if let first = staying.first {
            note = staying.count == 1
                ? "\(code: first) stays, because Roga leaves repositories and submodules alone."
                : "\(staying.count.formatted()) repositories and submodules stay, because Roga leaves those alone."
        }
        return DialogContent(
            id: "discard",
            title: "Discard all uncommitted changes?",
            message: changes.head == nil ? "Nothing has been committed yet, so the worktree goes back to empty." : "The worktree goes back to \(code: "HEAD").",
            cards: [rows],
            note: note,
            terminal: terminal,
            buttons: [
                .cancel(cancelDiscard),
                losesSomething
                    ? DialogButton(title: "Discard everything", kind: .destructive, action: confirmingDiscard)
                    : DialogButton(title: "Move to Trash", kind: .primary, action: confirmingDiscard),
            ],
            dismiss: cancelDiscard
        )
    }

    /// As in `1 changed file` or `2 changed files`.
    private static func files(_ count: Int, _ kind: String) -> String {
        count == 1 ? "1 \(kind) file" : "\(count.formatted()) \(kind) files"
    }
}
