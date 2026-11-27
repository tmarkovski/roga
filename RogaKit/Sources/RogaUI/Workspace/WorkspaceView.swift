import AppKit
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

/// Says how far the pointer is from the leading edge of the window, or nil once
/// it has left. It's an AppKit tracking area behind the window's views rather
/// than SwiftUI's hover, which hit-tests the views under the pointer again
/// whenever they move, as they all do on every frame while the sidebar's line
/// is dragged.
private struct PointerTracker: NSViewRepresentable {
    let moved: (Double?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.moved = moved
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.moved = moved
    }

    final class TrackingView: NSView {
        var moved: (Double?) -> Void = { _ in }

        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        required init?(coder: NSCoder) {
            fatalError("The tracker is made in code.")
        }

        /// Lets every click through to the views in front.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { moved(nil) }

        private func report(_ event: NSEvent) {
            moved(convert(event.locationInWindow, from: nil).x)
        }
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
                monitor.selected(worktree: worktree)
            }
            .onChange(of: shownState) {
                monitor.showing(worktree: worktree, appearsActive: appearsActive, in: list)
            }
            .onChange(of: appearsActive) {
                monitor.showing(worktree: worktree, appearsActive: appearsActive, in: list)
            }
    }

    /// What agents are doing in the worktree.
    private var shownState: AgentSummary.State? {
        guard let worktree else { return nil }
        return monitor.summary(forWorktree: worktree, in: list)?.state
    }
}

/// Hands on to the model of the worktree a window shows what changed on disk,
/// which the list of repositories hears from the repository's session. It's a
/// view of its own, so that a change to another of the repository's worktrees
/// updates nothing else in the window. A model that isn't showing hears
/// nothing, and looks for itself when it shows again.
private struct DiskChangesSeen: View {
    let repository: ListedRepository
    /// The folder of the worktree the window shows.
    let worktree: String
    let model: RepositoryModel

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: repository.refsChange) { _, change in
                model.refsChangedOnDisk(asNewAs: change)
            }
            .onChange(of: repository.fileChanges[worktree]) { _, change in
                if let change { model.filesChangedOnDisk(asNewAs: change) }
            }
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
    /// Setup, which takes the window over the first time Roga runs.
    @Environment(SetupModel.self) private var setup
    @State private var recent = RecentWorktrees()
    @State private var columns = NavigationSplitViewVisibility.all
    @SceneStorage("showsRefsPanel") private var wantsRefsPanel = true
    /// How much room the panels under history take in this window.
    @SceneStorage("lowerPanelSize") private var lowerPanelSize = LowerPanelSize.regular
    @AppStorage("refsPanelWidth") private var refsPanelWidth = RefsPanelVisibility.defaultWidth
    /// Whether the refs panel fits in the column that holds the worktree and the
    /// panel. It's kept rather than the column's width, which changes on every
    /// frame of a drag and would update the whole window each time.
    @State private var refsPanelFits = true
    /// Whether the window is in full screen, where the title row keeps no room
    /// for the traffic lights, since they slide down with the menu bar.
    @State private var isFullScreen = false
    /// Where the middle's part of the title row starts, from the window's
    /// leading edge, which moves as the sidebar shows or hides.
    @State private var titleRowMinX: CGFloat = 0
    @State private var sidebarLine = SidebarLineHover()
    @State private var showsSettings = false
    /// The sidebar row whose popover for a new worktree is open (decision 82).
    @State private var newWorktreeRow: WorktreeSelection?
    /// Whether Clone Repository… asked the sidebar for Add Repositories' clone
    /// form (decision 113).
    @State private var asksToClone = false
    /// The worktree whose popover for a new worktree is open on its tab, or on
    /// the button after the tabs for the main worktree (decision 95).
    @State private var newWorktreeTab: WorktreeSelection?
    /// Deleting a worktree, and finding a worktree's missing folder, from the
    /// menu of its tab. The sidebar has its own for its rows' menus.
    @State private var tabDeletions = WorktreeDeletionModel()
    @State private var tabRepairs = WorktreeRepairModel()
    @Environment(\.openWindow) private var openWindow
    /// Which window `openSettings` shows Settings on, which keeps it equal from
    /// one update of the window to the next.
    @State private var settingsWindow = UUID()
    /// Settings asked for with no Roga window in front, which a new window shows.
    @Environment(SettingsRequest.self) private var settingsRequest: SettingsRequest?
    /// Whether the dialog for Report an Issue… shows on this window (decision 94).
    @State private var showsIssueReport = false
    /// Report an Issue… chosen with no Roga window in front, which a new window
    /// shows.
    @Environment(IssueReportRequest.self) private var issueReportRequest: IssueReportRequest?
    @Environment(\.openURL) private var openURL

    public init(window: Binding<WorkspaceWindow?>) {
        _window = window
    }

    private var selection: Binding<WorktreeSelection?> {
        Binding {
            window?.selection
        } set: { selection in
            var changed = window ?? WorkspaceWindow()
            changed.selection = selection
            window = changed
        }
    }

    public var body: some View {
        Group {
            // Setup fades out before the app fades in, since the two are
            // laid out differently and neither reads through the other.
            if setup.isShowing {
                SetupView(setup: setup)
                    .transition(SetupMotion.fade)
            } else {
                workspace
                    .transition(SetupMotion.fade)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        // Roga's own traffic lights, in the title row's middle (decision 96).
        // Over setup too, so that they don't move when it ends.
        .overlay(alignment: .topLeading) {
            TitleRowCorner {
                TrafficLights(isFullScreen: $isFullScreen)
                    .padding(.leading, TitleBar.trafficLightsLeading)
            }
        }
        // On the window rather than the workspace, so that someone stuck in
        // setup, such as without a git that works, can report it too.
        .dialog {
            guard showsIssueReport else { return nil }
            return .issueReport(.current(git: gitProvider), open: { openURL($0) }, dismiss: { showsIssueReport = false })
        }
        .focusedSceneValue(\.showsIssueReport, $showsIssueReport)
        .onAppear {
            if issueReportRequest?.isPending == true {
                issueReportRequest?.isPending = false
                showsIssueReport = true
            }
        }
        .task(id: Connection(hasGit: gitProvider.git != nil, isSettingUp: setup.isShowing, usesAgents: agents.usesAgents)) {
            guard let git = gitProvider.git else { return }
            // The agents run with git's environment, and the monitor asks
            // Claude Code about its sessions once Roga has found it with
            // its hooks installed. Both belong to the app, so starting
            // them from another window does nothing. Setup needs both, to
            // find the agents and to install their hooks. With agents turned
            // off, nothing listens for their hooks (decision 89).
            agents.start(git: git)
            // Setup asks about the agents, so it needs them found even when
            // they were turned off.
            if setup.isShowing { agents.lookIfNotYet() }
            if agents.usesAgents || setup.isShowing {
                agentMonitor.start(agents: agents)
            } else {
                agentMonitor.stop()
            }
            // The repositories open with one git and keep it, so they wait
            // for setup, where someone may choose another.
            if !setup.isShowing {
                await list.connect(git: git, showing: Set([window?.selection?.repository].compactMap(\.self)))
            }
        }
    }

    /// When to start what needs git: once there's a git, and again once
    /// setup is over.
    private struct Connection: Hashable {
        var hasGit: Bool
        var isSettingUp: Bool
        var usesAgents: Bool
    }

    /// The sidebar and the worktree selected in it.
    private var workspace: some View {
        NavigationSplitView(columnVisibility: $columns) {
            VStack(spacing: 0) {
                // The sidebar's part of the title row, which the traffic
                // lights and the sidebar's button sit over.
                TitleRowDragArea()
                    .frame(height: TitleBar.height)
                Sidebar(list: list, monitor: agentMonitor, selection: selection, showsSettings: $showsSettings, locate: locate, newWorktreeRow: $newWorktreeRow, createWorktree: createWorktree, asksToClone: $asksToClone)
            }
            .ignoresSafeArea(.container, edges: .top)
            .overlay(alignment: .trailing) {
                // A line between the sidebar and the worktree, from the
                // top of the window to the bottom.
                SidebarLine(hover: sidebarLine)
                    .ignoresSafeArea()
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { sidebarLine.sidebarWidth = $0 }
            // Or macOS adds a button of its own, and a toolbar to hold it.
            .toolbar(removing: .sidebarToggle)
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
                VStack(spacing: 0) {
                    titleRow
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } side: { _ in
                refsPanel
            }
            // The title row and the refs panel's header go up to the top of
            // the window, where the traffic lights are.
            .ignoresSafeArea(.container, edges: .top)
            .background(Palette.surface)
            .onGeometryChange(for: Bool.self) { RefsPanelVisibility.fits(column: $0.size.width) } action: { refsPanelFits = $0 }
        }
        // The button that hides the sidebar stays beside the traffic lights,
        // over both columns, whether the sidebar shows or not, so that it
        // doesn't move when it's clicked and nothing slides under it.
        .overlay(alignment: .topLeading) {
            TitleRowCorner {
                SidebarToggle(visibility: $columns)
                    .padding(.leading, TitleBar.sidebarButtonLeading(isFullScreen: isFullScreen))
            }
        }
        .background {
            PointerTracker { sidebarLine.pointerMoved(toX: $0) }
                .ignoresSafeArea()
        }
        .dialog { tabDeletions.dialog ?? tabRepairs.dialog }
        .navigationTitle(title)
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
        .background {
            if let selected = window?.selection, let (repository, worktree) = shown, worktree != nil, let model = shownModel {
                DiskChangesSeen(repository: repository, worktree: selected.worktree, model: model)
                    .id(selected)
            }
        }
        .focusedSceneValue(\.selection, selection)
        .focusedSceneValue(\.worktreeCommands, worktreeCommands)
        .focusedSceneValue(\.sidebarVisibility, $columns)
        .focusedSceneValue(\.asksToClone, $asksToClone)
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
        RefsPanelVisibility(isWanted: refsPanelWanted, fits: refsPanelFits)
    }

    /// Whether the panels under history are maximized over the room the refs
    /// panel would take.
    private var coversRefsPanel: Bool {
        lowerPanelSize == .maximized && shownModel?.phase.isReady == true
    }

    /// Whether the refs panel is wanted. It isn't while the panels under history
    /// cover its room, and asking for it then puts them back, so that Show Refs
    /// and switching branches still show it.
    private var refsPanelWanted: Binding<Bool> {
        let isCovered = coversRefsPanel
        let wantsRefsPanel = $wantsRefsPanel
        let lowerPanelSize = $lowerPanelSize
        return Binding {
            wantsRefsPanel.wrappedValue && !isCovered
        } set: { wanted in
            if wanted, isCovered { lowerPanelSize.wrappedValue = .regular }
            wantsRefsPanel.wrappedValue = wanted
        }
    }

    /// The refs of the repository whose worktree the window shows.
    @ViewBuilder private var refsPanel: some View {
        if let selected = window?.selection,
           let repository = list.repository(at: selected.repository),
           case .open(let session) = repository.state,
           repository.worktrees.contains(where: { $0.path == selected.worktree }) {
            RefsPanel(model: model(for: selected, session: session), visibility: refsPanelVisibility, showWorktree: showWorktree(of: selected, session: session))
                .id(selected)
        } else {
            RefsPanelPlaceholder(visibility: refsPanelVisibility)
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
        let isBare = list.repository(at: selected.repository)?.worktrees.first { $0.path == selected.worktree }?.isBare ?? false
        return recent.model(for: selected, session: session, isBare: isBare) { [list] count, failure in
            list.setUncommittedFiles(count, failure: failure, in: selected)
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
                Label("Can't Use Git", icon: .warning)
            } description: {
                Text(error.description)
            } actions: {
                // Where every git Roga found is listed, to choose another.
                Button("Git Settings…") { openSettings(.page(.git)) }
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
                    Button("Clone Repository…", action: cloneRepository)
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
        case .cloning(let job):
            ContentUnavailableView {
                Label("Cloning \(repository.name)", icon: .cloudDownload)
            } description: {
                Text(CloneLine(job: job).spoken)
            } actions: {
                Button("Cancel Clone") { list.cancelClone(repository) }
                    .disabled(job.isCancelling)
            }
        case .open(let session):
            if let worktree = repository.worktrees.first(where: { $0.path == selected.worktree }) {
                let model = self.model(for: selected, session: session)
                let showWorktree = self.showWorktree(of: selected, session: session)
                // The branch's row stays above history while the panels under
                // it are maximized, as the title row did before it.
                VStack(spacing: 0) {
                    BranchBar(
                        model: model,
                        worktree: worktree,
                        monitor: agentMonitor,
                        list: list,
                        repositoryName: repository.name,
                        switchBranch: refsPanelVisibility.fits ? {
                            refsPanelVisibility.isWanted.wrappedValue = true
                            model.refs.showFilter()
                        } : nil,
                        unlock: { tabRepairs.unlock(worktree, in: repository, list: list) },
                        showWorktree: showWorktree
                    )
                    RepositoryView(model: model, showWorktree: showWorktree, lowerPanelSize: $lowerPanelSize)
                }
                // For who the worktree's commits go out as, in the message box
                // (decision 105).
                .environment(repository)
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

    /// The middle's part of the row along the top of the window, which Roga
    /// draws itself (decision 96). It has the shown repository's worktrees as
    /// tabs (decision 95), or the repository's name until it's open and git has
    /// listed them. When there's no room, the tabs get narrower and their names
    /// fade out at their ends. The tabs keep clear of the traffic lights and
    /// the sidebar's button, which stay in the window's corner, wherever the
    /// row is as the sidebar shows or hides. After the tabs comes who the
    /// repository's commits go out as, for every worktree and agent in it
    /// (decision 105). While the refs panel is hidden, the row ends with the
    /// panel's button, where the panel has it (decision 85).
    private var titleRow: some View {
        HStack(spacing: 0) {
            tabs
                .padding(.leading, titleRowLeading + 8)
                // As tall as the row, so that cutting off the tabs that don't
                // fit leaves the shown tab's shadow under it.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .clipped()
            if let repository = shown?.0 {
                IdentityButton(repository: repository, list: list)
                    .padding(.leading, 8)
            }
            if !refsPanelVisibility.isShowing {
                RefsPanelToggle(visibility: refsPanelVisibility)
                    .padding(.leading, 8)
            }
        }
        .padding(.trailing, TitleBar.trailingInset)
        .frame(height: TitleBar.height)
        .animation(.easeOut(duration: 0.2), value: shown?.0.identity == nil)
        .background {
            TitleRowDragArea()
        }
        // Behind the drag area, which has to be on top to take presses.
        .background(Palette.titleRow)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { titleRowMinX = $0 }
    }

    /// How much of the middle's row, from its leading end, the traffic lights
    /// and the sidebar's button cover. While the sidebar is hidden, the row
    /// starts at the window's edge, under both. While it shows, they're over
    /// the sidebar, once the row has moved out from under them: the split
    /// view moves the row a frame or two after the sidebar is asked to show.
    private var titleRowLeading: CGFloat {
        let corner = TitleBar.cornerWidth(isFullScreen: isFullScreen)
        if columns == .detailOnly { return corner }
        return max(0, corner - titleRowMinX)
    }

    @ViewBuilder private var tabs: some View {
        Group {
            if let selected = window?.selection, let repository = shown?.0, !repository.worktrees.isEmpty {
                WorktreeTabStrip(
                    repository: repository,
                    shown: selected.worktree,
                    model: shownModel,
                    monitor: agentMonitor,
                    list: list,
                    actions: tabActions(for: repository),
                    newWorktreeFrom: $newWorktreeTab
                )
            } else {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize()
                    .help(title)
                    // In line with a tab's icon, when there are tabs.
                    .padding(.leading, 9)
            }
        }
        .lineLimit(1)
    }

    /// What the tabs of a repository's worktrees do, which is what the rows of
    /// the sidebar do for them.
    private func tabActions(for repository: ListedRepository) -> WorktreeTabActions {
        func selected(_ folder: String) -> WorktreeSelection {
            WorktreeSelection(repository: repository.path, worktree: folder)
        }
        return WorktreeTabActions(
            show: { folder in
                selection.wrappedValue = selected(folder)
            },
            openInNewWindow: { folder in
                openWindow(value: WorkspaceWindow(selection: selected(folder)))
            },
            createWorktree: { folder, name in
                await createWorktree(from: selected(folder), named: name)
            },
            locate: { worktree in
                tabRepairs.locate(worktree, in: repository, list: list) { selection.wrappedValue = $0 }
            },
            delete: { worktree in
                tabDeletions.askToDelete(worktree, in: repository, list: list)
            },
            unlock: { worktree in
                tabRepairs.unlock(worktree, in: repository, list: list)
            },
            locateRepository: { locate(repository) },
            removeRepository: { list.remove(repository) }
        )
    }

    /// What the menu bar's worktree commands do for the worktree on screen.
    private func worktreeMenuActions(shown worktree: Worktree, selected: WorktreeSelection, model: RepositoryModel?) -> WorktreeMenu.Actions {
        WorktreeMenu.Actions(
            show: { folder in
                selection.wrappedValue = WorktreeSelection(repository: selected.repository, worktree: folder)
            },
            newWorktree: model.flatMap { model in
                model.branch.isBusy || worktree.isBare ? nil : { startNewWorktree(from: selected) }
            },
            reveal: reveal,
            openInTerminal: openInTerminal
        )
    }

    /// What the menu bar does with the worktree on screen, and the other
    /// worktrees of its repository, in the order of their tabs.
    private var worktreeCommands: WorktreeCommands? {
        guard let selected = window?.selection, let (repository, worktree) = shown, let worktree else { return nil }
        return WorktreeMenu.commands(of: repository, shown: worktree, actions: worktreeMenuActions(shown: worktree, selected: selected, model: shownModel))
    }

    private func open() {
        openRepository(list: list) { selection.wrappedValue = $0 }
    }

    /// Opens Add Repositories on its clone form. The sidebar shows it, since
    /// the popover hangs from its row.
    private func cloneRepository() {
        asksToClone = true
    }

    private func locate(_ repository: ListedRepository) {
        locateRepository(repository, list: list) { selection.wrappedValue = $0 }
    }

    /// What the menu bar's New Worktree… does for the worktree on screen: it opens
    /// the popover on that worktree's tab, or for the main worktree on the button
    /// after the tabs (decision 95). The tabs show whether or not the sidebar
    /// does, so there's always somewhere to hang it from.
    private func startNewWorktree(from selected: WorktreeSelection) {
        newWorktreeTab = selected
    }

    /// Makes a new branch in a new worktree, from the worktree of the sidebar row
    /// whose popover asked, and shows it. The window needn't show that worktree
    /// first, so the command runs here rather than through its model, which may
    /// not exist (decision 82).
    ///
    /// - Returns: What git said if it refused, which the popover shows.
    private func createWorktree(from row: WorktreeSelection, named name: String) async -> String? {
        guard let repository = list.repository(at: row.repository), case .open(let session) = repository.state else { return nil }
        // Nothing runs in a worktree while git does something else there, as in
        // the title row.
        let model = recent.existingModel(for: row)
        if model?.branch.isBusy == true {
            return "git is still running in this worktree. Try again once it's done."
        }
        do {
            try await session.create(NewBranch(name: name, inNewWorktree: true), in: row.worktree)
        } catch {
            return (error as? GitError)?.message ?? String(describing: error)
        }
        if newWorktreeRow == row { newWorktreeRow = nil }
        if newWorktreeTab == row { newWorktreeTab = nil }
        // The window can only show a worktree the sidebar knows about.
        await list.refresh(repositoryAt: row.repository)
        model?.refsChanged()
        if let created = try? await session.worktrees().first(where: { $0.branch == Ref.branchPrefix + name }) {
            showWorktree(of: row, session: session)(created.path, created.head)
        }
        return nil
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
    ///   - isBare: Whether the worktree is a bare repository's entry, which
    ///     has no files to list.
    ///   - reportUncommittedFiles: What a new model calls with how many
    ///     uncommitted files it finds, or what git said when it couldn't list
    ///     them.
    ///   - reportConflicts: What a new model calls with whether it finds conflicts.
    ///   - reportBranchChange: What a new model calls when it has put the
    ///     worktree on another branch or made a new worktree, which returns once
    ///     the sidebar knows.
    func model(
        for selection: WorktreeSelection,
        session: RepositorySession,
        isBare: Bool = false,
        reportUncommittedFiles: @escaping (_ count: Int, _ failure: String?) -> Void = { _, _ in },
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
            isBare: isBare,
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

    /// The model of a worktree the window showed lately, without making one or
    /// counting it as shown.
    func existingModel(for selection: WorktreeSelection) -> RepositoryModel? {
        models[selection]
    }
}
