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
    /// The same for the row for uncommitted changes, where the diff needs the room
    /// for staging and the message needs it for writing (decision 30). It's 0 until
    /// someone drags it.
    @AppStorage("changesPanelHeight") private var changesPanelHeight = 0.0
    @AppStorage("commitPanelWidth") private var commitPanelWidth = 320.0
    @AppStorage(FileListSettings.layout) private var fileLayout = FileLayout.list

    var body: some View {
        // Handing the panels bindings doesn't count as reading these, so a change
        // to one wouldn't update this view. A worktree that's loading gets other
        // updates that cover for that. One that has already loaded may get none,
        // and a drag would change the saved size and leave the line where it was.
        let _ = (commitPanelHeight, changesPanelHeight, commitPanelWidth)
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
            .modifier(RepositoryDialogs(model: model))
    }

    /// How much of history shows beside uncommitted changes until someone drags the
    /// split: the row for them and four commits, enough to see a commit land.
    private static let historyHeightWithChanges = 4.0 + 5 * 28

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
            let showsChanges = model.selectedChanges.isSelected
            PanelSplit(
                lowerHeight: showsChanges ? $changesPanelHeight : $commitPanelHeight,
                upperHeightUntilDragged: Self.historyHeightWithChanges
            ) {
                HistoryPanel(model: model, showWorktree: showWorktree)
            } lower: {
                PanelColumns(leadingWidth: $commitPanelWidth) {
                    if showsChanges {
                        ChangesPanel(selection: model.selectedChanges, composer: model.composer)
                    } else {
                        CommitPanel(model: model)
                    }
                } trailing: {
                    DiffPanel(selection: model.selectedFile, changes: showsChanges ? model.selectedChanges : nil)
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

/// The list of commits. It has no header, because what it would say is at the
/// right end of the title row: how many commits there are, and its commands.
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

/// A checkout that's taking a while, which says so before the branch's buttons in
/// the title row, so that its words opening moves nothing to their right.
struct CheckoutNote: ToolbarContent {
    let model: RepositoryModel

    /// How wide it is, for leaving room for it.
    static func width(for branch: String) -> Double {
        let text = "Checking out \(branch)…" as NSString
        return text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width.rounded(.up)
    }

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
    }
}

/// History's part of the title row: how many commits it shows, and its commands.
/// The window declares it, because macOS puts the items of a view inside another
/// after that view's, and the button for the refs panel has to come last.
struct HistoryCommands: ToolbarContent {
    @Bindable var model: RepositoryModel
    /// How wide the left part of the title row is, and the middle of the window.
    let titleRow: TitleRowWidth
    /// How much of the middle's width the rest of the title row takes.
    let titleRowTaken: Double

    /// The font of the number of commits.
    private static let commitCountFont = NSFont.systemFont(ofSize: 12)

    /// Whether the number of commits has room. It's the first thing to go when the
    /// row is short of room, before the branch's name truncates. The toolbar keeps
    /// an item's room after what's in it has shrunk, so the item comes and goes,
    /// by how wide its words are.
    private func showsCommitCount(_ commits: String) -> Bool {
        var width = (commits as NSString).size(withAttributes: [.font: Self.commitCountFont]).width.rounded(.up)
        if let branch = model.slowCheckout { width += CheckoutNote.width(for: branch) + TitleRowWidth.toolbarSpacing }
        return titleRow.leavesRoom(for: width, besides: titleRowTaken)
    }

    var body: some ToolbarContent {
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
        if let commits = model.commitCountDescription, showsCommitCount(commits) {
            // Every commit history shows, from every branch, remote branch and
            // tag, rather than the branch's, so it goes with history's commands.
            ToolbarItem {
                Text(commits)
                    .font(Font(Self.commitCountFont))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help("History shows \(commits), from every branch, remote branch and tag")
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
