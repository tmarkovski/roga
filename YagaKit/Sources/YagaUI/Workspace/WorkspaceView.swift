import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import SwiftUI

/// What a window shows, which SwiftUI saves with the window. Each window has
/// an ID of its own, so that opening a worktree in a new window opens one
/// even when another window shows that worktree.
public struct WorkspaceWindow: Codable, Hashable, Sendable {
    public var id = UUID()
    public var selection: WorktreeSelection?
    /// Where the sidebar is. It's optional because a window saved by an earlier
    /// version doesn't have it.
    var sidebar: SidebarPlace?

    public init(selection: WorktreeSelection? = nil) {
        self.selection = selection
    }
}

/// The contents of a yaga window: the sidebar, and the worktree selected in
/// it.
public struct WorkspaceView: View {
    @Binding var window: WorkspaceWindow?
    @Environment(GitProvider.self) private var gitProvider
    @Environment(RepositoryList.self) private var list
    @State private var recent = RecentWorktrees()
    @State private var columns = NavigationSplitViewVisibility.all
    @SceneStorage("showsRefsPanel") private var wantsRefsPanel = true
    @SceneStorage("showsOrganizationRail") private var showsRail = true
    @AppStorage("refsPanelWidth") private var refsPanelWidth = RefsPanelVisibility.defaultWidth
    /// The width of the column that holds the worktree and the refs panel, once
    /// it's been laid out.
    @State private var columnWidth: Double?
    /// The width of the middle of the window, once it's been laid out.
    @State private var middleWidth: Double?

    public init(window: Binding<WorkspaceWindow?>) {
        _window = window
    }

    private var selection: Binding<WorktreeSelection?> {
        Binding {
            window?.selection
        } set: { selection in
            var changed = window ?? WorkspaceWindow()
            changed.selection = selection
            if let selection {
                var place = changed.sidebar ?? SidebarPlace()
                place.record(selection, in: list.groups)
                changed.sidebar = place
            }
            window = changed
        }
    }

    private var place: Binding<SidebarPlace> {
        Binding {
            window?.sidebar ?? SidebarPlace()
        } set: { place in
            var changed = window ?? WorkspaceWindow()
            changed.sidebar = place
            window = changed
        }
    }

    /// What the rail shows as selected. Setting it picks a scope, which also
    /// shows the worktree the window showed there last.
    private var scope: Binding<SidebarScope> {
        Binding {
            place.wrappedValue.effectiveScope(in: list.groups, showsRail: showsRail)
        } set: { scope in
            if scope != .all { showsRail = true }
            var changed = window ?? WorkspaceWindow()
            var place = changed.sidebar ?? SidebarPlace()
            place.scope = scope
            if let shown = list.selectionToShow(in: scope, place: place, current: changed.selection) {
                changed.selection = shown
                place.record(shown, in: list.groups)
            }
            changed.sidebar = place
            window = changed
        }
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(list: list, selection: selection, scope: scope, place: place, showsRail: showsRail, locate: locate)
                .overlay(alignment: .trailing) {
                    // A line between the sidebar and the worktree, from the
                    // top of the window to the bottom.
                    Rectangle()
                        .fill(Palette.separator)
                        .frame(width: 1)
                        .ignoresSafeArea()
                }
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    // macOS keeps the sidebar's toolbar items next to the
                    // traffic lights while the sidebar is hidden.
                    ToolbarItem {
                        SidebarToggle(visibility: $columns)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                // It has to come last, or macOS ignores it and opens a new
                // window with a sidebar 144 points wide.
                .navigationSplitViewColumnWidth(min: 256, ideal: 312, max: 400)
        } detail: {
            SidePanelColumns(
                isShown: refsPanelVisibility.isShowing,
                width: $refsPanelWidth,
                minimumWidth: RefsPanelVisibility.defaultWidth,
                maximumWidth: RefsPanelVisibility.maximumWidth,
                minimumMainWidth: RefsPanelVisibility.minimumMiddleWidth
            ) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: Double.self) { $0.size.width } action: { middleWidth = $0 }
            } side: { width in
                refsPanel(width: width)
            }
            // A line at the bottom of the title row, from the sidebar to the
            // edge of the window, like the one in a panel's header. It replaces
            // macOS's own, which is thinner and sits under the row.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1)
                    .offset(y: -1)
                    .allowsHitTesting(false)
            }
            .background(Palette.surface)
            .onGeometryChange(for: Double.self) { $0.size.width } action: { columnWidth = $0 }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    titleRow
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
                if let model = shownModel, case .ready = model.phase {
                    HistoryCommands(model: model)
                }
                ToolbarItem {
                    RefsPanelToggle(visibility: refsPanelVisibility)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .navigationTitle(title)
        .frame(minWidth: 720, minHeight: 480)
        .task(id: gitProvider.git != nil) {
            if let git = gitProvider.git { await list.connect(git: git) }
        }
        .onAppear {
            // A new window, or one macOS didn't restore, shows the worktree
            // selected last.
            if window?.selection == nil { selection.wrappedValue = list.lastSelection }
        }
        .onChange(of: window?.selection) { _, selected in
            if let selected { list.lastSelection = selected }
        }
        .onChange(of: list.resolve(window?.selection)) { _, resolved in
            if resolved != window?.selection { selection.wrappedValue = resolved }
        }
        .focusedSceneValue(\.selection, selection)
        .focusedSceneValue(\.sidebarScope, scope)
        .focusedSceneValue(\.showsOrganizationRail, $showsRail)
        .focusedSceneValue(\.sidebarVisibility, $columns)
        .focusedSceneValue(\.refsPanelVisibility, refsPanelVisibility)
    }

    private var refsPanelVisibility: RefsPanelVisibility {
        RefsPanelVisibility(isWanted: $wantsRefsPanel, fits: columnWidth.map(RefsPanelVisibility.fits) ?? true)
    }

    /// The refs of the repository whose worktree the window shows.
    @ViewBuilder private func refsPanel(width: Double) -> some View {
        if let selected = window?.selection,
           let repository = list.repository(at: selected.repository),
           case .open(let session) = repository.state,
           repository.worktrees.contains(where: { $0.path == selected.worktree }) {
            RefsPanel(model: model(for: selected, session: session), width: width, isShown: $wantsRefsPanel, showWorktree: showWorktree(of: selected))
                .id(selected)
        } else {
            RefsPanelPlaceholder(width: width)
        }
    }

    /// What shows another of a repository's worktrees in the window, by its folder.
    private func showWorktree(of selected: WorktreeSelection) -> (String) -> Void {
        { worktree in
            selection.wrappedValue = WorktreeSelection(repository: selected.repository, worktree: worktree)
        }
    }

    private func model(for selected: WorktreeSelection, session: RepositorySession) -> RepositoryModel {
        recent.model(for: selected, session: session) { [list] count in
            list.setUncommittedFiles(count, in: selected)
        } reportBranchChange: { [list] in
            Task { await list.refresh(repositoryAt: selected.repository) }
        }
    }

    @ViewBuilder private var detail: some View {
        switch gitProvider.state {
        case .locating:
            ProgressView()
                .controlSize(.small)
        case .failed(let error):
            ContentUnavailableView {
                Label("yaga Can't Use Git", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.description)
            }
        case .ready:
            if let selected = window?.selection, let repository = list.repository(at: selected.repository) {
                detail(repository, selected)
            } else if list.repositories.isEmpty {
                ContentUnavailableView {
                    Label("No Repository Open", systemImage: "folder")
                } description: {
                    Text("Open a repository to see its history.")
                } actions: {
                    Button("Open Repository…", action: open)
                }
            } else {
                ContentUnavailableView(
                    "No Worktree Selected",
                    systemImage: "sidebar.left",
                    description: Text("Choose a worktree in the sidebar to see its history.")
                )
            }
        }
    }

    @ViewBuilder private func detail(_ repository: ListedRepository, _ selected: WorktreeSelection) -> some View {
        switch repository.state {
        case .opening:
            ProgressView()
                .controlSize(.small)
        case .missing:
            ContentUnavailableView {
                Label("Can't Find \(repository.name)", systemImage: "questionmark.folder")
            } description: {
                Text("It was at \(repository.path), and it has been moved or deleted.")
            } actions: {
                Button("Locate…") { locate(repository) }
                Button("Remove from Sidebar") { list.remove(repository) }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Show \(repository.name)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await list.refresh() } }
            }
        case .open(let session):
            if repository.worktrees.contains(where: { $0.path == selected.worktree }) {
                RepositoryView(model: model(for: selected, session: session), showWorktree: showWorktree(of: selected))
                    .id(selected)
            } else {
                // The worktree is gone, and resolving the selection moves the
                // window to the main worktree.
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var shown: (ListedRepository, Worktree?)? {
        guard let selected = window?.selection, let repository = list.repository(at: selected.repository) else { return nil }
        return (repository, repository.worktrees.first { $0.path == selected.worktree })
    }

    private var title: String { shown?.0.name ?? "yaga" }

    /// The model of the worktree the window shows, once its repository is open.
    private var shownModel: RepositoryModel? {
        guard let selected = window?.selection, let (repository, worktree) = shown, worktree != nil,
              case .open(let session) = repository.state else { return nil }
        return model(for: selected, session: session)
    }

    /// The worktree's branch, and how many commits it has once they've been read.
    private var subtitle: String {
        guard let worktree = shown?.1 else { return "" }
        guard let commits = shownModel?.commitCountDescription else { return worktree.title }
        return "\(worktree.title) · \(commits)"
    }

    /// What the window shows, on one line like the title of a panel.
    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .help("\(title) \(subtitle)")
        // In line with the titles of the panels below it.
        .padding(.leading, 6)
        .frame(maxWidth: titleRowWidth, alignment: .leading)
    }

    /// How wide the title can get, because the toolbar moves what doesn't fit
    /// into a menu, starting with the commands after it.
    private var titleRowWidth: Double {
        guard let middleWidth else { return .infinity }
        // History's order button, the button for the refs panel, and the space
        // the toolbar keeps around them.
        var taken = 125.0
        // The window's buttons and the button for the sidebar.
        if columns == .detailOnly { taken += 140 }
        // The note about the commit-graph file.
        if shownModel?.historyWasSlowToLoad == true { taken += 180 }
        return max(0, middleWidth - taken)
    }

    private func open() {
        openRepository(list: list) { selection.wrappedValue = $0 }
    }

    private func locate(_ repository: ListedRepository) {
        locateRepository(repository, list: list) { selection.wrappedValue = $0 }
    }
}

/// The models of the worktrees a window showed last, so that going back to
/// one shows its history at once rather than loading it again.
final class RecentWorktrees {
    /// How many worktrees to keep. History for Linux takes about 30 MB.
    static let limit = 8

    private var models: [WorktreeSelection: RepositoryModel] = [:]
    /// The selections, from the one shown longest ago to the latest.
    private var order: [WorktreeSelection] = []

    /// - Parameters:
    ///   - reportUncommittedFiles: What a new model calls with how many
    ///     uncommitted files it finds.
    ///   - reportBranchChange: What a new model calls when it has put the
    ///     worktree on another branch.
    func model(
        for selection: WorktreeSelection,
        session: RepositorySession,
        reportUncommittedFiles: @escaping (Int) -> Void = { _ in },
        reportBranchChange: @escaping () -> Void = {}
    ) -> RepositoryModel {
        order.removeAll { $0 == selection }
        order.append(selection)
        // A repository that was removed and added again has a new session.
        if let model = models[selection], model.session === session { return model }
        let model = RepositoryModel(
            session: session,
            worktree: selection.worktree,
            reportUncommittedFiles: reportUncommittedFiles,
            reportBranchChange: reportBranchChange
        )
        models[selection] = model
        while order.count > Self.limit {
            models[order.removeFirst()] = nil
        }
        return model
    }
}
