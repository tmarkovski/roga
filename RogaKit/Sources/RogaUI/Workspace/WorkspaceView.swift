import Foundation
import GitCore
import GitRunner
import IconUI
import MenuUI
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

/// Whether the pointer is over the area that drags the line after the sidebar.
/// macOS handles that drag and takes the mouse there from the views on both
/// sides, so this goes by where the pointer is, in the area macOS 26 drags from.
/// Only the line reads it, so that the window doesn't update each time.
@MainActor @Observable private final class SidebarLineHover {
    private(set) var isPointerOver = false
    @ObservationIgnored var sidebarWidth = 0.0

    func pointerMoved(toX x: Double?) {
        let isOver = x.map { (-2.5 ..< 3).contains($0 - sidebarWidth) } ?? false
        if isOver != isPointerOver { isPointerOver = isOver }
    }
}

private struct SidebarLine: View {
    let hover: SidebarLineHover

    var body: some View {
        // Nothing can draw past the sidebar, so it stands out from the edge inward.
        PanelLine(axis: .horizontal, isPointerOver: hover.isPointerOver, alignment: .trailing)
    }
}

/// Showing a worktree is looking at it, so this tells the agent monitor that
/// what finished there has been seen: when it's selected, when an agent
/// finishes in it while the window is in front, and when the window comes to
/// the front.
///
/// It's a view of its own, which draws nothing, because watching for an agent
/// finishing reads the marks: only this view updates each time a mark changes
/// anywhere, rather than the whole window.
private struct AgentMarksSeen: View {
    let monitor: AgentMonitor
    let list: RepositoryList
    /// The folder of the worktree the window shows.
    let worktree: String?
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: worktree, initial: true) { _, worktree in
                if let worktree { monitor.markSeen(worktree: worktree) }
            }
            .onChange(of: shownState) {
                markSeenIfFinished()
            }
            .onChange(of: appearsActive) {
                markSeenIfFinished()
            }
    }

    /// What agents are doing in the worktree.
    private var shownState: AgentSummary.State? {
        guard let worktree else { return nil }
        return monitor.summary(forWorktree: worktree, in: list)?.state
    }

    private func markSeenIfFinished() {
        guard appearsActive, shownState == .finished, let worktree else { return }
        monitor.markSeen(worktree: worktree)
    }
}

/// The contents of a Roga window: the sidebar, and the worktree selected in
/// it.
public struct WorkspaceView: View {
    @Binding var window: WorkspaceWindow?
    @Environment(GitProvider.self) private var gitProvider
    @Environment(RepositoryList.self) private var list
    @Environment(AgentProvider.self) private var agents
    @Environment(AgentMonitor.self) private var agentMonitor
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
    @State private var sidebarLine = SidebarLineHover()
    @State private var showsSettings = false
    /// Which window `openSettings` shows Settings on, which keeps it equal from
    /// one update of the window to the next.
    @State private var settingsWindow = UUID()
    /// Settings asked for with no Roga window in front, which a new window shows.
    @Environment(SettingsRequest.self) private var settingsRequest: SettingsRequest?

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
                    SidebarLine(hover: sidebarLine)
                        .ignoresSafeArea()
                }
                .onGeometryChange(for: Double.self) { $0.size.width } action: { sidebarLine.sidebarWidth = $0 }
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
                .navigationSplitViewColumnWidth(min: 256, ideal: 312, max: 560)
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
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): sidebarLine.pointerMoved(toX: location.x)
            case .ended: sidebarLine.pointerMoved(toX: nil)
            }
        }
        .navigationTitle(title)
        .frame(minWidth: 720, minHeight: 480)
        .task(id: gitProvider.git != nil) {
            if let git = gitProvider.git {
                // The agents run with git's environment, and the monitor asks
                // Claude Code about its sessions once Roga has found it with
                // its hooks installed. Both belong to the app, so starting
                // them from another window does nothing.
                agents.start(git: git)
                agentMonitor.start(agents: agents)
                await list.connect(git: git)
            }
        }
        .onAppear {
            // A new window, or one macOS didn't restore, shows the worktree
            // selected last.
            if window?.selection == nil { selection.wrappedValue = list.lastSelection }
            if settingsRequest?.isPending == true {
                settingsRequest?.isPending = false
                showsSettings = true
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsSheet()
        }
        .onChange(of: window?.selection) { previous, selected in
            if let selected { list.lastSelection = selected }
            if let previous { list.keepShowing(previous) }
        }
        .background {
            AgentMarksSeen(monitor: agentMonitor, list: list, worktree: window?.selection?.worktree)
        }
        .onChange(of: list.resolve(window?.selection)) { _, resolved in
            if resolved != window?.selection { selection.wrappedValue = resolved }
        }
        .onChange(of: shown?.0.deletionCount) {
            shownModel?.refsChanged()
        }
        .focusedSceneValue(\.selection, selection)
        .focusedSceneValue(\.sidebarScope, scope)
        .focusedSceneValue(\.showsOrganizationRail, $showsRail)
        .focusedSceneValue(\.sidebarVisibility, $columns)
        .focusedSceneValue(\.refsPanelVisibility, refsPanelVisibility)
        .focusedSceneValue(\.showsSettings, $showsSettings)
        .environment(\.openSettings, openSettings)
        .focusedSceneValue(\.openSettings, openSettings)
    }

    /// Shows Settings on this window at a page or an agent's page. Storing the
    /// destination first means a sheet that's already showing goes there too.
    private var openSettings: ShowSettingsAction {
        let showsSettings = $showsSettings
        return ShowSettingsAction(window: settingsWindow) { destination in
            destination.store()
            showsSettings.wrappedValue = true
        }
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
            RefsPanel(model: model(for: selected, session: session), width: width, isShown: $wantsRefsPanel, showWorktree: showWorktree(of: selected, session: session))
                .id(selected)
        } else {
            RefsPanelPlaceholder(width: width)
        }
    }

    /// What shows another of a repository's worktrees in the window, by its
    /// folder, because of a branch that it has checked out. The worktree's model
    /// remembers what was selected the last time it showed, so the branch's commit
    /// replaces that.
    private func showWorktree(of selected: WorktreeSelection, session: RepositorySession) -> (String, ObjectID?) -> Void {
        { worktree, commit in
            let shown = WorktreeSelection(repository: selected.repository, worktree: worktree)
            if let commit { model(for: shown, session: session).select(commit: commit) }
            selection.wrappedValue = shown
        }
    }

    private func model(for selected: WorktreeSelection, session: RepositorySession) -> RepositoryModel {
        recent.model(for: selected, session: session) { [list] count in
            list.setUncommittedFiles(count, in: selected)
        } reportConflicts: { [list] hasConflicts in
            list.setHasConflicts(hasConflicts, in: selected)
        } reportBranchChange: { [list] in
            await list.refresh(repositoryAt: selected.repository)
        }
    }

    @ViewBuilder private var detail: some View {
        switch gitProvider.state {
        case .locating:
            ProgressView()
                .controlSize(.small)
        case .failed(let error):
            ContentUnavailableView {
                Label("Roga Can't Use Git", icon: .warning)
            } description: {
                Text(error.description)
            }
        case .ready:
            if let selected = window?.selection, let repository = list.repository(at: selected.repository) {
                detail(repository, selected)
            } else if list.repositories.isEmpty {
                ContentUnavailableView {
                    Label("No Repository Open", icon: .folder)
                } description: {
                    Text("Open a repository to see its history.")
                } actions: {
                    Button("Open Repository…", action: open)
                }
            } else {
                ContentUnavailableView {
                    Label("No Worktree Selected", icon: .panelLeft)
                } description: {
                    Text("Choose a worktree in the sidebar to see its history.")
                }
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
                Label("Can't Find \(repository.name)", icon: .folderSearch)
            } description: {
                Text("It was at \(repository.path), and it has been moved or deleted.")
            } actions: {
                Button("Locate…") { locate(repository) }
                Button("Remove from Sidebar") { list.remove(repository) }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Show \(repository.name)", icon: .warning)
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await list.refresh() } }
            }
        case .open(let session):
            if repository.worktrees.contains(where: { $0.path == selected.worktree }) {
                RepositoryView(model: model(for: selected, session: session), showWorktree: showWorktree(of: selected, session: session))
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

    private var title: String { shown?.0.name ?? "Roga" }

    /// The model of the worktree the window shows, once its repository is open.
    private var shownModel: RepositoryModel? {
        guard let selected = window?.selection, let (repository, worktree) = shown, worktree != nil,
              case .open(let session) = repository.state else { return nil }
        return model(for: selected, session: session)
    }

    /// What the window shows, on one line like the title of a panel: the
    /// repository, the worktree's branch and what can be done with it, and how many
    /// commits it has once they've been read. When there's no room, the number of
    /// commits goes first, then the branch's name truncates, and the counts stay.
    private var titleRow: some View {
        HStack(spacing: 6) {
            if let (repository, worktree) = shown, let worktree, let selected = window?.selection {
                RepositoryChip(
                    name: repository.name,
                    isMain: worktree.isMain,
                    entries: worktreeMenu(of: repository, shown: worktree, selected: selected)
                )
                .fixedSize()
            } else {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize()
                    .help(title)
                    // In line with the chip's icon, when there is one.
                    .padding(.leading, 5)
            }
            if let (_, worktree) = shown, let worktree {
                if let selected = window?.selection, let model = shownModel, !worktree.isBare {
                    BranchControl(
                        branch: model.branch,
                        worktree: worktree,
                        switchBranch: refsPanelVisibility.fits ? {
                            refsPanelVisibility.isWanted.wrappedValue = true
                            model.refs.showFilter()
                        } : nil,
                        showWorktree: { folder, commit in
                            if case .open(let session) = shown?.0.state {
                                showWorktree(of: selected, session: session)(folder, commit)
                            }
                        }
                    )
                    .layoutPriority(1)
                } else {
                    Text(worktree.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                if let commits = shownModel?.commitCountDescription {
                    ViewThatFits(in: .horizontal) {
                        Text("· \(commits)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
            }
        }
        .lineLimit(1)
        // The chip's icon is in line with the titles of the panels below it,
        // and its hover fill reaches out past that.
        .padding(.leading, 1)
        .frame(maxWidth: titleRowWidth, alignment: .leading)
    }

    /// The menu of the shown repository's worktrees, which the chip with its name
    /// opens.
    private func worktreeMenu(of repository: ListedRepository, shown worktree: Worktree, selected: WorktreeSelection) -> [RefMenu.Entry] {
        let model = shownModel
        return WorktreeMenu.entries(
            for: WorktreeMenu.facts(of: repository, shown: worktree.path, model: model),
            shown: worktree.path,
            actions: WorktreeMenu.Actions(
                show: { folder in
                    selection.wrappedValue = WorktreeSelection(repository: selected.repository, worktree: folder)
                },
                newWorktree: model.flatMap { model in
                    model.branch.isBusy || worktree.isBare ? nil : { model.branch.startNewWorktree() }
                },
                reveal: reveal,
                openInTerminal: openInTerminal
            )
        )
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
    ///   - reportConflicts: What a new model calls with whether it finds conflicts.
    ///   - reportBranchChange: What a new model calls when it has put the
    ///     worktree on another branch or made a new worktree, which returns once
    ///     the sidebar knows.
    func model(
        for selection: WorktreeSelection,
        session: RepositorySession,
        reportUncommittedFiles: @escaping (Int) -> Void = { _ in },
        reportConflicts: @escaping (Bool) -> Void = { _ in },
        reportBranchChange: @escaping () async -> Void = {}
    ) -> RepositoryModel {
        order.removeAll { $0 == selection }
        order.append(selection)
        // A repository that was removed and added again has a new session.
        if let model = models[selection], model.session === session { return model }
        let model = RepositoryModel(
            session: session,
            worktree: selection.worktree,
            reportUncommittedFiles: reportUncommittedFiles,
            reportConflicts: reportConflicts,
            reportBranchChange: reportBranchChange
        )
        models[selection] = model
        while order.count > Self.limit {
            models[order.removeFirst()] = nil
        }
        return model
    }
}
