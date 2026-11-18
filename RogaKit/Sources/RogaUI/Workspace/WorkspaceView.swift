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

/// How wide the left part of the title row is, and the middle of the window it
/// sits over, which only the number of commits at the row's other end reads.
/// Both change on every frame, the first while words open and close after the
/// branch, the second while a line beside the middle is dragged, and this way
/// that redraws history's commands rather than the whole window.
@MainActor @Observable final class TitleRowWidth {
    /// How wide it is, once it's been laid out.
    var shown: Double?
    /// How wide the middle of the window is, once it's been laid out.
    var middle: Double?
    /// About how much space the toolbar keeps between two items.
    static let toolbarSpacing = 12.0

    /// The most the left part can take, given how much of the middle's width
    /// the rest of the row takes, or nil before the window has been laid out.
    func room(besides taken: Double) -> Double? {
        middle.map { max(0, $0 - taken) }
    }

    /// Whether something this wide fits beside it, given how much of the
    /// middle's width the rest of the row takes. Before the window has been laid
    /// out, everything fits.
    func leavesRoom(for width: Double, besides taken: Double) -> Bool {
        guard let available = room(besides: taken), let shown else { return true }
        return available - shown >= width + Self.toolbarSpacing
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
    @State private var titleRowShown = TitleRowWidth()
    /// The most the left part of the title row can take, once the window has
    /// been laid out. It's kept apart from the middle's width, and changes only
    /// when that changes what the row shows (`updateTitleRowRoom`).
    @State private var titleRowRoom: Double?
    @State private var sidebarLine = SidebarLineHover()
    @State private var showsSettings = false
    /// The sidebar row whose popover for a new worktree is open (decision 82).
    @State private var newWorktreeRow: WorktreeSelection?
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
            if !setup.isShowing { await list.connect(git: git) }
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
            Sidebar(list: list, monitor: agentMonitor, selection: selection, showsSettings: $showsSettings, locate: locate, newWorktreeRow: $newWorktreeRow, createWorktree: createWorktree)
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
                    .onGeometryChange(for: Double.self) { $0.size.width } action: {
                        titleRowShown.middle = $0
                        updateTitleRowRoom()
                    }
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
            .onGeometryChange(for: Bool.self) { RefsPanelVisibility.fits(column: $0.size.width) } action: { refsPanelFits = $0 }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    titleRow
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
                if let model = shownModel, case .ready = model.phase {
                    CheckoutNote(model: model)
                }
                branchButtons
                if let model = shownModel, case .ready = model.phase {
                    HistoryCommands(model: model, titleRow: titleRowShown, titleRowTaken: titleRowTaken)
                }
                // While the panel shows, the button is the last of its row.
                if !refsPanelVisibility.isShowing {
                    ToolbarItem {
                        RefsPanelToggle(visibility: refsPanelVisibility)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
        }
        .background {
            PointerTracker { sidebarLine.pointerMoved(toX: $0) }
                .ignoresSafeArea()
        }
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
        .onChange(of: titleRowTaken) {
            updateTitleRowRoom()
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
    @ViewBuilder private func refsPanel(width: Double) -> some View {
        if let selected = window?.selection,
           let repository = list.repository(at: selected.repository),
           case .open(let session) = repository.state,
           repository.worktrees.contains(where: { $0.path == selected.worktree }) {
            RefsPanel(model: model(for: selected, session: session), width: width, visibility: refsPanelVisibility, showWorktree: showWorktree(of: selected, session: session))
                .id(selected)
        } else {
            RefsPanelPlaceholder(width: width, visibility: refsPanelVisibility)
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
                RepositoryView(model: model(for: selected, session: session), showWorktree: showWorktree(of: selected, session: session), lowerPanelSize: $lowerPanelSize)
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
    /// repository, then the worktree's branch and how far it is from its upstream.
    /// When there's no room, the number of commits at the other end of the row
    /// goes first, then the branch's name truncates, down to a few letters, then
    /// the repository's name does. The counts stay, and so do Fetch and New Branch.
    private var titleRow: some View {
        HStack(spacing: 6) {
            if let (repository, worktree) = shown, let worktree, let selected = window?.selection {
                let model = shownModel
                WorktreeChip(
                    repository: repository,
                    worktree: worktree,
                    model: model,
                    actions: worktreeMenuActions(shown: worktree, selected: selected, model: model),
                    monitor: agentMonitor,
                    list: list
                )
                // Ahead of the branch, so that its name only truncates once
                // the branch's is as short as it goes.
                .layoutPriority(2)
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
            }
        }
        .lineLimit(1)
        // The chip's icon is in line with the titles of the panels below it,
        // and its hover fill reaches out past that.
        .padding(.leading, 1)
        // Inside the frame, which can be wider than what's in it, so that it's
        // how wide the row really is. The number of commits gets what's left.
        .onGeometryChange(for: Double.self) { $0.size.width } action: {
            titleRowShown.shown = $0
            updateTitleRowRoom()
        }
        .frame(maxWidth: titleRowRoom ?? .infinity, alignment: .leading)
    }

    /// Gives the title row the room it has now, when that changes what it shows.
    /// While the row has room to spare, before and after, its frame doesn't hold
    /// it in, so a new room changes nothing, and leaving it alone keeps a drag
    /// beside the middle from updating the whole window on every frame. Once the
    /// row is near its room or cut short, the room changes the row, and the whole
    /// toolbar has to update for macOS to measure the row again, or it keeps the
    /// row's old width and moves the commands at the other end into a menu.
    private func updateTitleRowRoom() {
        guard let room = titleRowShown.room(besides: titleRowTaken) else { return }
        let toSpare = (titleRowShown.shown ?? 0) + Self.titleRowRoomToSpare
        if let current = titleRowRoom, current >= toSpare, room >= toSpare { return }
        if room != titleRowRoom { titleRowRoom = room }
    }

    /// How much more room than it takes the title row has to have before a
    /// change of room is left alone.
    private static let titleRowRoomToSpare = 24.0

    /// Fetch and New Branch, at the right end of the title row before history's
    /// commands, for a worktree with a branch to act on.
    @ToolbarContentBuilder private var branchButtons: some ToolbarContent {
        if let (_, worktree) = shown, let worktree, !worktree.isBare,
           let selected = window?.selection, let model = shownModel {
            ToolbarItem {
                HStack(spacing: Self.branchButtonsGap) {
                    BranchButtons(branch: model.branch, worktree: worktree) { folder, commit in
                        if case .open(let session) = shown?.0.state {
                            showWorktree(of: selected, session: session)(folder, commit)
                        }
                    }
                    // A line between them and history's commands, which they
                    // don't act on, once history has loaded and they show.
                    if model.phase.isReady {
                        Rectangle()
                            .fill(Palette.separator)
                            .frame(width: 1, height: Self.branchButtonsLineHeight)
                            .padding(.trailing, Self.branchButtonsLineTrailing)
                            .accessibilityHidden(true)
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    /// What the menu of the shown repository's worktrees does, which the chip
    /// with its name opens.
    private func worktreeMenuActions(shown worktree: Worktree, selected: WorktreeSelection, model: RepositoryModel?) -> WorktreeMenu.Actions {
        WorktreeMenu.Actions(
            show: { folder in
                selection.wrappedValue = WorktreeSelection(repository: selected.repository, worktree: folder)
            },
            newWorktree: model.flatMap { model in
                model.branch.isBusy || worktree.isBare ? nil : { startNewWorktree(from: selected, model: model) }
            },
            reveal: reveal,
            openInTerminal: openInTerminal
        )
    }

    /// What the menu bar does with the worktree on screen, as the menu of its
    /// repository's worktrees does.
    private var worktreeCommands: WorktreeCommands? {
        guard let selected = window?.selection, let (repository, worktree) = shown, let worktree else { return nil }
        return WorktreeMenu.commands(of: repository, shown: worktree, actions: worktreeMenuActions(shown: worktree, selected: selected, model: shownModel))
    }

    /// The space between the branch's buttons and the line after them. A button
    /// is wider than its icon, and the toolbar puts space of its own after the
    /// line, so with `branchButtonsLineTrailing` the line has about 14 points
    /// on each side, between New Branch's icon and the number of commits.
    private static let branchButtonsGap = 6.0
    /// The space after the line, besides what the toolbar puts there.
    private static let branchButtonsLineTrailing = 4.0
    /// How tall the line after the branch's buttons is, about as tall as their
    /// icons.
    private static let branchButtonsLineHeight = 16.0
    /// How far apart macOS puts two toolbar items of one button each, measured
    /// on macOS 27: what the refs panel's button takes from the middle of the
    /// title row while the panel is hidden.
    private static let refsPanelButtonPitch = 44.0

    /// How much of the middle's width the rest of the title row takes, which
    /// leaves the most the title can get, because the toolbar moves what doesn't
    /// fit into a menu, starting with the commands after it. The number of
    /// commits doesn't count, because it goes first, when it doesn't fit what's
    /// left.
    private var titleRowTaken: Double {
        // History's order button and the space the toolbar keeps around it.
        var taken = 125.0 - Self.refsPanelButtonPitch
        // The button for the refs panel, while the panel is hidden. While it
        // shows, the button is in the panel's own row (decision 85).
        if !refsPanelVisibility.isShowing { taken += Self.refsPanelButtonPitch }
        // Fetch and New Branch, the line after them, and the toolbar's space
        // before them.
        if let (_, worktree) = shown, let worktree, !worktree.isBare, shownModel != nil {
            taken += 2 * 28 + 2 + Self.branchButtonsGap + 1 + Self.branchButtonsLineTrailing + TitleRowWidth.toolbarSpacing
        }
        // The window's buttons and the button for the sidebar.
        if columns == .detailOnly { taken += 140 }
        // The note about the commit-graph file.
        if shownModel?.historyWasSlowToLoad == true { taken += 180 }
        return taken
    }

    private func open() {
        openRepository(list: list) { selection.wrappedValue = $0 }
    }

    private func locate(_ repository: ListedRepository) {
        locateRepository(repository, list: list) { selection.wrappedValue = $0 }
    }

    /// What the menu bar's New Worktree… does for the worktree on screen: it opens
    /// the popover on that worktree's row in the sidebar (decision 82). While the
    /// sidebar is hidden, there's no row to hang it from, so New Branch opens in
    /// the title row with In a new worktree ticked.
    private func startNewWorktree(from selected: WorktreeSelection, model: RepositoryModel) {
        if columns == .detailOnly {
            model.branch.startNewWorktree()
        } else {
            newWorktreeRow = selected
        }
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
