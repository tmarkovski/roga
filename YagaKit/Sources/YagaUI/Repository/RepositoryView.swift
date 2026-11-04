import AppKit
import CommitGraph
import GitCore
import GitRunner
import IconUI
import RepositoryEngine
import SwiftUI

/// One worktree: its history, and the commit and file selected in it.
struct RepositoryView: View {
    let model: RepositoryModel
    /// Shows one of the repository's worktrees in the window, by its folder,
    /// with a commit selected in it.
    let showWorktree: (String, ObjectID?) -> Void
    @AppStorage("commitPanelHeight") private var commitPanelHeight = 340.0
    @AppStorage("commitPanelWidth") private var commitPanelWidth = 320.0
    @AppStorage(FileListSettings.layout) private var fileLayout = FileLayout.list

    var body: some View {
        content
            .task(id: model.loadRequest) {
                model.updateCommitGraph()
                await model.appear()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.becameActive()
            }
            .onChange(of: fileLayout, initial: true) {
                model.fileList.layout = fileLayout
            }
            .focusedSceneValue(\.repository, model)
            .alert(
                "Can't Check Out \(model.checkoutFailure?.branch ?? "")",
                isPresented: Binding { model.checkoutFailure != nil } set: { if !$0 { model.checkoutFailure = nil } },
                presenting: model.checkoutFailure
            ) { _ in
            } message: { failure in
                Text(failure.message)
            }
            .alert(
                model.branch.failure?.title ?? "",
                isPresented: Binding { model.branch.failure != nil } set: { if !$0 { model.branch.failure = nil } },
                presenting: model.branch.failure
            ) { _ in
            } message: { failure in
                Text(failure.message)
            }
            .alert(
                "The Pull Stopped on a Conflict",
                isPresented: Binding { model.branch.conflict != nil } set: { if !$0 { model.branch.conflict = nil } },
                presenting: model.branch.conflict
            ) { _ in
                Button("Undo the Pull") { model.branch.undoPull() }
                Button("Leave It", role: .cancel) {}
            } message: { conflict in
                Text(conflictMessage(conflict))
            }
            .modifier(AbortAlert(branch: model.branch))
            .alert(
                "Force Push \(model.branch.forcePush?.branch ?? "")?",
                isPresented: Binding { model.branch.forcePush != nil } set: { if !$0 { model.branch.forcePush = nil } },
                presenting: model.branch.forcePush
            ) { _ in
                Button("Force Push", role: .destructive) { model.branch.confirmForcePush() }
                Button("Cancel", role: .cancel) {}
            } message: { push in
                Text(forcePushMessage(push))
            }
            .alert(
                model.branch.pendingDeletion.map(deletionTitle) ?? "",
                isPresented: Binding { model.branch.pendingDeletion != nil } set: { if !$0 { model.branch.pendingDeletion = nil } },
                presenting: model.branch.pendingDeletion
            ) { _ in
                Button("Delete", role: .destructive) { model.branch.confirmDeletion() }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(deletionMessage(pending))
            }
    }

    private func deletionTitle(_ pending: BranchModel.PendingDeletion) -> String {
        if case .remote(let remote, let branch) = pending.deletion.place { return "Delete \(branch) from \(remote)?" }
        return "Delete \(pending.deletion.shortName)?"
    }

    /// What a deletion loses, as the vision asks of destructive operations, and
    /// the command, since it can't be taken back from here.
    private func deletionMessage(_ pending: BranchModel.PendingDeletion) -> String {
        let deletion = pending.deletion
        var parts: [String] = []
        if case .remote(let remote, _) = deletion.place {
            parts.append("This deletes the branch on \(remote), for everyone who uses it.")
        }
        if deletion.lostCount > 0 {
            var lost = deletion.lostCount == 1
                ? "1 commit isn't on any other branch or tag:\n"
                : "\(deletion.lostCount.formatted()) commits aren't on any other branch or tag:\n"
            lost += pending.subjects.map { "\n• \($0)" }.joined()
            if deletion.lostCount > pending.subjects.count { lost += "\n• and \((deletion.lostCount - pending.subjects.count).formatted()) more" }
            parts.append(lost)
        } else {
            parts.append("Its commits are all on other branches or tags, so none are lost.")
        }
        parts.append(BranchModel.command(deletion.arguments))
        return parts.joined(separator: "\n\n")
    }

    /// Which files a pull stopped on, and what can be done about them.
    private func conflictMessage(_ conflict: BranchModel.Conflict) -> String {
        let shown = conflict.files.prefix(5).joined(separator: ", ")
        let others = conflict.files.count - min(conflict.files.count, 5)
        let files = others > 0 ? "\(shown) and \(others.formatted()) more" : shown
        let advice = "yaga can't resolve conflicts yet, so you can undo the pull, or leave the worktree as it is to finish from the command line."
        return files.isEmpty ? advice : "These files conflict: \(files).\n\n\(advice)"
    }

    /// What a force push overwrites, as the vision asks of destructive operations.
    private func forcePushMessage(_ push: BranchModel.ForcePush) -> String {
        guard push.count > 0 else {
            return "This replaces \(push.upstream) with \(push.branch). It has no commits that \(push.branch) doesn't, so none are lost. git refuses if \(push.upstream) has moved since your branch last had it."
        }
        var message = push.count == 1
            ? "This overwrites 1 commit on \(push.upstream):\n"
            : "This overwrites \(push.count.formatted()) commits on \(push.upstream):\n"
        message += push.subjects.map { "\n• \($0)" }.joined()
        if push.count > push.subjects.count { message += "\n• and \((push.count - push.subjects.count).formatted()) more" }
        return message + "\n\ngit refuses if \(push.upstream) has commits that \(push.branch) never had."
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            LoadingHistory(explanation: model.slowHistoryExplanation)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Show This Repository", icon: .warning)
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.reload() }
            }
        case .ready:
            PanelSplit(lowerHeight: $commitPanelHeight) {
                HistoryPanel(model: model, showWorktree: showWorktree)
            } lower: {
                PanelColumns(leadingWidth: $commitPanelWidth) {
                    if model.selectedChanges.isSelected {
                        ChangesPanel(selection: model.selectedChanges)
                    } else {
                        CommitPanel(model: model)
                    }
                } trailing: {
                    DiffPanel(selection: model.selectedFile)
                }
            }
        }
    }
}

/// A spinner that says why, once history has taken a moment to load.
private struct LoadingHistory: View {
    var explanation: String?
    @State private var isTakingLong = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            if isTakingLong, let explanation {
                Text(explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            isTakingLong = true
        }
    }
}

/// The list of commits. It has no header, because what it would say is in the
/// title row: how many commits there are after the branch, and its commands at
/// the right end.
struct HistoryPanel: View {
    let model: RepositoryModel
    let showWorktree: (String, ObjectID?) -> Void

    var body: some View {
        Group {
            if let history = model.history, history.isComplete, history.rows.isEmpty, !model.hasWorkingTreeRow {
                ContentUnavailableView {
                    Label("No Commits Yet", icon: .clock)
                } description: {
                    Text("Commits appear here once there are some.")
                }
            } else {
                CommitList(model: model, version: model.historyVersion, selectedRow: model.selectedRow, showWorktree: showWorktree)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
    }
}

/// History's part of the title row. The window declares it, because macOS puts
/// the items of a view inside another after that view's, and the button for the
/// refs panel has to come last.
struct HistoryCommands: ToolbarContent {
    @Bindable var model: RepositoryModel

    var body: some ToolbarContent {
        if let branch = model.slowCheckout {
            ToolbarItem {
                Text("Checking out \(branch)…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if model.historyWasSlowToLoad, let explanation = model.slowHistoryExplanation {
            ToolbarItem {
                Group {
                    if model.commitGraphState == .updating {
                        Text("Writing commit-graph file…")
                    } else {
                        Label("Opens slowly", icon: .slow)
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(explanation)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItem {
            Menu {
                Picker("Order", selection: $model.sort) {
                    Text("Topological Order").tag(HistoryOrder.Sort.topological)
                    Text("Date Order").tag(HistoryOrder.Sort.date)
                }
                .pickerStyle(.inline)
            } label: {
                HoverIcon { Icon.filter.image }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Order of History")
            .accessibilityLabel("Order of History")
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

extension FocusedValues {
    /// The repository in the focused window, for the menu commands.
    @Entry var repository: RepositoryModel?
}

/// Asks before aborting a merge or a rebase. What it loses is said up front, as
/// the vision asks of destructive operations, along with the command, since it
/// can't be taken back from here.
private struct AbortAlert: ViewModifier {
    let branch: BranchModel

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding { branch.pendingAbort != nil } set: { if !$0 { branch.pendingAbort = nil } },
            presenting: branch.pendingAbort
        ) { _ in
            Button("Abort", role: .destructive) { branch.confirmAbort() }
            Button("Cancel", role: .cancel) {}
        } message: { work in
            Text(message(work))
        }
    }

    private var title: String {
        switch branch.pendingAbort {
        case .merge: "Abort the Merge?"
        case .rebase: "Abort the Rebase?"
        case nil: ""
        }
    }

    private func message(_ work: StoppedWork) -> String {
        let what = switch work {
        case .merge: "merge"
        case .rebase: "rebase"
        }
        return "This goes back to before the \(what), and any conflicts you've resolved are lost.\n\n\(BranchModel.command(work.abortArguments))"
    }
}
