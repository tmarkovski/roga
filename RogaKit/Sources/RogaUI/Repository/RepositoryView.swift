import AppKit
import CommitGraph
import GitCore
import GitRunner
import IconUI
import MenuUI
import RepositoryEngine
import SwiftUI

/// One worktree: its history, and the commit and file selected in it.
struct RepositoryView: View {
    let model: RepositoryModel
    /// Shows one of the repository's worktrees in the window, by its folder,
    /// with a commit selected in it.
    let showWorktree: (String, ObjectID?) -> Void
    /// How much room the panels under history take, which the window keeps.
    @Binding var lowerPanelSize: LowerPanelSize
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
        let _ = (commitPanelHeight, changesPanelHeight, commitPanelWidth, lowerPanelSize)
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
            .focusedSceneValue(\.lowerPanelSize, model.phase.isReady ? $lowerPanelSize : nil)
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
                lowerSize: $lowerPanelSize,
                upperHeightUntilDragged: Self.historyHeightWithChanges
            ) {
                HistoryPanel(model: model, showWorktree: showWorktree)
            } lower: {
                PanelColumns(leadingWidth: $commitPanelWidth) {
                    if showsChanges {
                        ChangesPanel(selection: model.selectedChanges, composer: model.composer, canStash: model.canStash, stash: model.stashChanges)
                    } else {
                        CommitPanel(model: model)
                    }
                } trailing: {
                    DiffPanel(
                        selection: model.selectedFile,
                        changes: showsChanges ? model.selectedChanges : nil,
                        submoduleCommands: SubmoduleCommands(stage: model.stageSubmodule, update: model.updateSubmodule),
                        size: $lowerPanelSize
                    )
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
/// right end of the branch's row above it: how many commits there are, and its
/// commands.
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
                CommitList(model: model, version: model.historyVersion, selectedRows: model.selectedRows, showWorktree: showWorktree)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
    }
}

/// A checkout that's taking a while, which says so before the branch's buttons in
/// the branch's row, so that its words opening moves nothing to their right.
struct CheckoutNote: View {
    let model: RepositoryModel

    var body: some View {
        if let branch = model.slowCheckout {
            Text("Checking out \(branch)…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// History's part of the branch's row: its order, whose menu says how many
/// commits history shows, which leaves the row's room to the agent (decision
/// 119), and a note while history opens slowly.
struct HistoryCommands: View {
    let model: RepositoryModel
    /// How big the order's button is, as big as the row's other buttons.
    var buttonSize: CGFloat = 32
    @State private var orderOpener = RefMenuOpener()

    var body: some View {
        HStack(spacing: 4) {
            if model.historyWasSlowToLoad, let explanation = model.slowHistoryExplanation {
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
                .fixedSize()
                .help(explanation)
                .padding(.trailing, 4)
            }
            orderMenu
        }
    }

    /// The order's button. It's one of Roga's own menus, as the sidebar's and
    /// the refs panel's are, so the order is a submenu that says which one is
    /// chosen.
    private var orderMenu: some View {
        let entries = Self.orderMenu(commits: model.commitCountDescription, sort: model.sort) { model.sort = $0 }
        // The refs panel's icon for sorting, since this orders history rather
        // than leaving anything out.
        return HoverIcon(size: buttonSize) { Icon.sort.image }
            .overlay { RefMenuArea(entries: entries, opensOnClick: true, opener: orderOpener) }
            .help("Order of History")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Order of History")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { orderOpener.open() }
            .accessibilityActions { refMenuActions(entries) }
    }

    /// The order's menu: how many commits history shows, or that it's still
    /// reading them, then the order in a submenu that says which, as the
    /// sidebar's Sort by does.
    ///
    /// The count is every commit history shows, from every branch, remote
    /// branch and tag, rather than the branch's, so it goes with history's
    /// order.
    static func orderMenu(commits: String?, sort: HistoryOrder.Sort, setSort: @escaping (HistoryOrder.Sort) -> Void) -> [RefMenu.Entry] {
        var entries: [RefMenu.Entry] = []
        if let commits {
            entries += [.header(RefMenu.Title(commits)), .divider]
        }
        entries.append(.submenu("Order", value: sort.title, entries: HistoryOrder.Sort.inMenus.map { option in
            .option(RefMenu.Title(option.title), isChecked: sort == option) { setSort(option) }
        }))
        return entries
    }
}

extension HistoryOrder.Sort {
    /// The orders, as the menus list them.
    static let inMenus: [Self] = [.topological, .date]

    /// What the order's menu calls it.
    var title: String {
        switch self {
        case .topological: "Topological"
        case .date: "Date"
        }
    }
}

extension FocusedValues {
    /// The repository in the focused window, for the menu commands.
    @Entry var repository: RepositoryModel?
}
