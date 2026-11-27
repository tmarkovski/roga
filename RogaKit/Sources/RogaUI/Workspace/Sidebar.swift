import AppKit
import GitCore
import IconUI
import MenuUI
import RepositoryEngine
import SwiftUI

/// The window's sidebar: rows for adding repositories and for Settings at the
/// top, and under them the list of repositories with their worktrees, in a
/// group for each organization unless the person turned that off
/// (docs/main-window.md, decision 53).
///
/// It draws its own rows rather than using a `List`, because its rows fill
/// with gray on hover and when selected, and swap a label for commands on
/// hover, which a sidebar list can't do. So it handles the arrow keys
/// itself.
///
/// A row that an agent is working in, waiting in or has finished in has a mark
/// for it (decision 41), unless the person turned the marks off in Settings.
struct Sidebar: View {
    let list: RepositoryList
    /// What agents are doing, which the rows read for their marks.
    let monitor: AgentMonitor
    @Binding var selection: WorktreeSelection?
    /// Whether the window shows Settings, which the row at the top opens.
    @Binding var showsSettings: Bool
    let locate: (ListedRepository) -> Void
    /// The row whose popover for a new worktree is open, which the menu bar's
    /// New Worktree… opens too (decision 82).
    @Binding var newWorktreeRow: WorktreeSelection?
    /// Makes a new branch in a new worktree from a row's worktree, and shows
    /// it. It returns what git said if it refused.
    let createWorktree: (WorktreeSelection, String) async -> String?
    /// Whether the menu bar's Clone Repository… asked for Add Repositories'
    /// clone form, which opens it and turns this back off (decision 113).
    @Binding var asksToClone: Bool
    /// Whether the rows show agents' marks, as the person chose in Settings.
    var marks = AgentMarksSetting()
    @AppStorage(SidebarSettings.groupsByOrganization) private var groupsByOrganization = true
    @AppStorage(SidebarSettings.sort) private var sort = SidebarSort.name
    /// The groups that are collapsed, one to a line. Like how the list is
    /// grouped and sorted, it's one setting for every window.
    @AppStorage(SidebarSettings.collapsedGroups) private var collapsedGroups = ""
    /// Whether linked worktrees have rows, which the tabs along the top of the
    /// window make optional (decision 95). It's one setting for every window too.
    @AppStorage(SidebarSettings.showsWorktrees) private var showsWorktrees = SidebarSettings.showsWorktreesByDefault
    /// The worktree this window showed last in each repository, by the
    /// repository's git directory, which a repository's row goes back to while
    /// worktrees have no rows of their own.
    @State private var lastShown: [String: WorktreeSelection] = [:]
    @State private var isAddingRepositories = false
    /// Opens the menu that groups and sorts the list for VoiceOver's press.
    @State private var arrangementOpener = RefMenuOpener()
    @State private var adding = AddRepositoriesState()
    @State private var deletions = WorktreeDeletionModel()
    @State private var repairs = WorktreeRepairModel()
    @FocusState private var isFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    /// A new version of Roga, which shows as a row under Settings.
    @Environment(Updates.self) private var updates: Updates?

    var body: some View {
        let groups = list.groups
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                SidebarCommandRow(title: "Add Repositories", icon: .plus, popover: $isAddingRepositories, isEnabled: list.isConnected) {
                    // With nothing listed and no folder picked, the popover
                    // has nowhere to look, so the row asks for a folder first.
                    if list.repositories.isEmpty && adding.pickedFolders.isEmpty {
                        lookInAnotherFolder()
                    } else {
                        isAddingRepositories = true
                    }
                }
                .popover(isPresented: $isAddingRepositories, arrowEdge: .trailing) {
                    AddRepositories(list: list, state: $adding, selection: $selection, lookInAnotherFolder: lookInAnotherFolder, chooseCloneFolder: chooseCloneFolder)
                }
                // Looks for clones as the window opens, so that the popover
                // opens at its full size the first time too. It takes a few
                // milliseconds, off the main actor.
                .task {
                    guard adding.found == nil else { return }
                    let found = await list.clonesToAdd(alsoLookingIn: adding.pickedFolders)
                    if adding.found == nil { adding.found = found }
                }
                // Settings isn't something the list can show, so it keeps the
                // gray of an open popover while the sheet is up.
                SidebarCommandRow(title: "Settings", icon: .settings, isOpen: showsSettings) {
                    showsSettings = true
                }
                if let updates, let pending = updates.pending {
                    SidebarCommandRow(title: pending.title, icon: .circleArrowUp, tint: Palette.action, action: updates.open)
                }
            }
            .padding(EdgeInsets(top: 2, leading: 8, bottom: 8, trailing: 8))
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
            ListHeader(title: "Repositories", count: groups.all.count) {
                arrangementMenu
            }
            .padding(.top, 6)
            rows(groups: groups)
        }
        .dialog { deletions.dialog ?? repairs.dialog }
        .onChange(of: asksToClone, initial: true) {
            guard asksToClone, list.isConnected else { return }
            asksToClone = false
            adding.source = .url
            isAddingRepositories = true
        }
    }

    /// How the list is grouped and sorted, and which groups are collapsed.
    private var arrangement: SidebarArrangement {
        SidebarArrangement(groupsByOrganization: groupsByOrganization, sort: sort, collapsed: SidebarArrangement.collapsed(from: collapsedGroups), showsWorktrees: showsWorktrees)
    }

    private func setCollapsed(_ isCollapsed: Bool, _ group: SidebarGroup) {
        var collapsed = SidebarArrangement.collapsed(from: collapsedGroups)
        if isCollapsed { collapsed.insert(group) } else { collapsed.remove(group) }
        collapsedGroups = SidebarArrangement.saved(collapsed)
    }

    /// The button at the right of the list's header, with a menu that groups
    /// and sorts the list and shows or hides worktrees, as the View menu does.
    /// It's one of Roga's own menus, which puts the checkmark at the right of
    /// the option that's chosen.
    private var arrangementMenu: some View {
        let entries = arrangementEntries
        return HoverIcon(size: 24) { Icon.slidersHorizontal.image }
            .overlay { RefMenuArea(entries: entries, opensOnClick: true, opener: arrangementOpener) }
            .help("Sidebar view options")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sidebar view options")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { arrangementOpener.open() }
            .accessibilityActions { refMenuActions(entries) }
    }

    private var arrangementEntries: [RefMenu.Entry] {
        SidebarMenus.arrangement(
            groupsByOrganization: groupsByOrganization,
            sort: sort,
            showsWorktrees: showsWorktrees,
            setGrouping: { groupsByOrganization = $0 },
            setSort: { sort = $0 },
            setShowsWorktrees: { showsWorktrees = $0 }
        )
    }

    /// Asks for a folder to look in, then shows the popover with the clones in
    /// it.
    private func lookInAnotherFolder() {
        askForFolder { chooseRepositoryFolder(message: "Choose a repository or a folder to scan.") } then: { folder in
            adding.pickedFolders.append(folder)
        }
    }

    /// Asks for a folder for the clone form to clone into, and picks it there.
    private func chooseCloneFolder() {
        askForFolder(choose: chooseCloneDestination) { folder in
            if !adding.clone.chosenFolders.contains(folder) { adding.clone.chosenFolders.append(folder) }
            adding.clone.folder = folder
        }
    }

    /// Asks for a folder with the open panel, and passes it to `then`. The
    /// popover closes while the open panel is up, because a popover can close
    /// by itself when another window takes over, and opens again after, unless
    /// the panel was cancelled before the popover was ever open.
    private func askForFolder(choose: @escaping () -> String?, then: @escaping (String) -> Void) {
        let wasOpen = isAddingRepositories
        isAddingRepositories = false
        Task {
            let folder = choose()
            if let folder { then(folder) }
            if folder != nil || wasOpen { isAddingRepositories = true }
        }
    }

    private func rows(groups: RepositoryGroups) -> some View {
        let arrangement = arrangement
        let layout = SidebarLayout(groups: groups, arrangement: arrangement, selection: selection)
        let items = layout.items
        return ScrollViewReader { scroller in
            ScrollView {
                // Lazy, so that a change of the sidebar's width, on every frame
                // while its line is dragged, lays out the rows in view rather
                // than every row in the list.
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
                // Only what loading changes, so that expanding a repository
                // or arranging the list still happens at once.
                .animation(SidebarMotion.movement(reducesMotion), value: LoadProgress(groups.all))
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                handle(press.key, items: items, scroller)
            }
            .focusedValue(\.deleteSelectedWorktree, deleteSelectedWorktree(items: items))
            .onChange(of: arrangement) {
                if let selection { scroller.scrollTo(row(showing: selection)) }
            }
            .onChange(of: selection, initial: true) { _, selection in
                if let selection { lastShown[selection.repository] = selection }
            }
            // The menu bar's New Worktree… opens the popover on the selected
            // row, which has to be in view for it to hang from.
            .onChange(of: newWorktreeRow) {
                if let newWorktreeRow { scroller.scrollTo(newWorktreeRow) }
            }
        }
    }

    @ViewBuilder private func row(_ item: SidebarItem) -> some View {
        switch item {
        case .group(let group, let title, let isCollapsed, _):
            GroupLabel(title: title, isCollapsed: isCollapsed, agents: agents(of: item)) {
                isFocused = true
                setCollapsed(!isCollapsed, group)
            }
        case .repository(let repository, let title, let detail):
            let home = repository.home
            // With worktrees hidden, the row stands for every worktree of its
            // repository: it's selected while the window shows any of them,
            // and goes back to the one this window showed last.
            // Its mark is then the most urgent of theirs, so that an agent
            // waiting in one still shows.
            let isSelected = showsWorktrees ? selection == home : selection?.repository == repository.path
            let rowAgents = showsWorktrees ? agents(of: item) : agents(forWorktrees: repository.worktrees.map(\.path))
            RepositoryRow(repository: repository, list: list, title: title, detail: detail, standsForWorktrees: !showsWorktrees, isSelected: isSelected, isOpen: newWorktreeRow == home, agents: rowAgents) {
                if showsWorktrees {
                    select(home)
                } else if selection?.repository != repository.path {
                    select(lastShownWorktree(of: home))
                } else {
                    isFocused = true
                }
            } toggle: {
                isFocused = true
                list.setExpanded(!repository.isExpanded, repository)
            } openInNewWindow: {
                openWindow(value: WorkspaceWindow(selection: home))
            } locate: {
                locate(repository)
            } newWorktree: {
                newWorktreeRow = home
            }
            .modifier(newWorktreePopover(on: home, from: repository.worktrees.first))
            .id(home)
        case .worktree(let repository, let worktree, let isLast):
            let row = WorktreeSelection(repository: repository.path, worktree: worktree.path)
            WorktreeRow(
                worktree: worktree,
                uncommittedFiles: repository.uncommittedFiles[worktree.path] ?? 0,
                hasConflicts: repository.conflictedWorktrees.contains(worktree.path),
                statusFailure: .worktree(repository.statusFailures[worktree.path]),
                unfinished: repository.unfinishedWork[worktree.path],
                isLoading: !repository.hasCounted,
                isDeleting: repository.deletingWorktrees.contains(worktree.path),
                isSelected: selection == row,
                isOpen: newWorktreeRow == row,
                isLast: isLast,
                agents: agents(of: item)
            ) {
                select(row)
            } openInNewWindow: {
                openWindow(value: WorkspaceWindow(selection: row))
            } newWorktree: {
                newWorktreeRow = row
            } locate: {
                repairs.locate(worktree, in: repository, list: list) { select($0) }
            } delete: {
                deletions.askToDelete(worktree, in: repository, list: list)
            } unlock: {
                repairs.unlock(worktree, in: repository, list: list)
            }
            .modifier(newWorktreePopover(on: row, from: worktree))
            .id(row)
        case .hiddenWorktrees(let repository, let title, _, let uncommittedFiles, let hasConflicts, let statusFailures):
            HiddenWorktreesRow(title: title, uncommittedFiles: uncommittedFiles, hasConflicts: hasConflicts, statusFailure: .hidden(statusFailures), agents: agents(of: item)) {
                isFocused = true
                list.setExpanded(true, repository)
            }
        }
    }

    /// The popover for a new worktree, which hangs from the row of the worktree
    /// it starts from, the way Add Repositories' hangs from its row, rather than
    /// from the row's + button, which goes once the pointer leaves the row.
    private func newWorktreePopover(on row: WorktreeSelection, from worktree: Worktree?) -> NewWorktreePopoverModifier {
        NewWorktreePopoverModifier(
            isPresented: Binding {
                newWorktreeRow == row
            } set: { isPresented in
                if isPresented {
                    newWorktreeRow = row
                } else if newWorktreeRow == row {
                    newWorktreeRow = nil
                }
            },
            start: worktree.flatMap(NewWorktreePopover.start(of:))
        ) { name in
            await createWorktree(row, name)
        }
    }

    /// Where a row finds what agents are doing in the worktrees it stands for,
    /// or nil while the marks are turned off.
    func agents(of item: SidebarItem) -> RowAgents? {
        agents(forWorktrees: item.markedWorktrees)
    }

    /// Where a row finds what agents are doing in these worktrees, by their
    /// folders, or nil while the marks are turned off.
    private func agents(forWorktrees worktrees: [String]) -> RowAgents? {
        marks.monitor(monitor).map { RowAgents(monitor: $0, list: list, worktrees: worktrees) }
    }

    /// The row that shows a worktree: its own, or with worktrees hidden, its
    /// repository's.
    private func row(showing selection: WorktreeSelection) -> WorktreeSelection {
        guard !showsWorktrees, let repository = list.repository(at: selection.repository) else { return selection }
        return repository.home
    }

    /// What a repository's row shows while worktrees are hidden: the worktree
    /// this window showed last in the repository, while it's still there, or
    /// else the main worktree.
    private func lastShownWorktree(of home: WorktreeSelection) -> WorktreeSelection {
        lastShown[home.repository].flatMap { list.resolve($0) } ?? home
    }

    private func select(_ row: WorktreeSelection) {
        isFocused = true
        selection = row
    }

    /// What asks to delete the selected row's worktree, as its menu does, for the menu
    /// bar's command. A main worktree has no such row, because git won't remove it.
    private func deleteSelectedWorktree(items: [SidebarItem]) -> (() -> Void)? {
        for case .worktree(let repository, let worktree, _) in items
        where WorktreeSelection(repository: repository.path, worktree: worktree.path) == selection
            && !repository.deletingWorktrees.contains(worktree.path) {
            return { deletions.askToDelete(worktree, in: repository, list: list) }
        }
        return nil
    }

    /// The up and down arrows move between the worktrees showing. The right and
    /// left arrows show and hide the linked worktrees of the selected one's
    /// repository.
    private func handle(_ key: KeyEquivalent, items: [SidebarItem], _ scroller: ScrollViewProxy) -> KeyPress.Result {
        switch key {
        case .upArrow, .downArrow:
            let rows: [WorktreeSelection] = items.compactMap { item in
                switch item {
                case .repository(let repository, _, _):
                    repository.home
                case .worktree(let repository, let worktree, _) where !worktree.isPrunable:
                    WorktreeSelection(repository: repository.path, worktree: worktree.path)
                default:
                    nil
                }
            }
            let step = key == .downArrow ? 1 : -1
            let shownRow = selection.map { row(showing: $0) }
            let index = (rows.firstIndex { $0 == shownRow } ?? (step > 0 ? -1 : rows.count)) + step
            guard rows.indices.contains(index) else { return .handled }
            select(showsWorktrees ? rows[index] : lastShownWorktree(of: rows[index]))
            scroller.scrollTo(rows[index])
            return .handled
        case .leftArrow, .rightArrow:
            // With worktrees hidden, there are none to show or hide.
            guard showsWorktrees, let selection, let repository = list.repository(at: selection.repository) else { return .ignored }
            list.setExpanded(key == .rightArrow, repository)
            return .handled
        default:
            return .ignored
        }
    }
}

/// A row at the top of the sidebar for something other than a repository:
/// adding repositories, Settings, or a new version of Roga. It's as tall as the
/// list's rows and fills the same way, with an icon before its title. It keeps
/// the darker gray while what it opened is up, which isn't a selection but
/// says where the popover or sheet came from.
private struct SidebarCommandRow: View {
    let title: String
    let icon: Icon
    var isOpen = false
    /// The popover the row opens, if it opens one, which then opens as the
    /// mouse button goes down, and keeps the row gray while it's open.
    var popover: Binding<Bool>?
    var isEnabled = true
    /// The color of a row that stands out, as a new version does in the
    /// brand's orange.
    var tint: Color?
    let action: () -> Void

    var body: some View {
        if let popover {
            row(isOpen: popover.wrappedValue)
                .opensOnPress(popover, isEnabled: isEnabled, open: action)
        } else {
            row(isOpen: isOpen)
        }
    }

    private func row(isOpen: Bool) -> some View {
        SidebarRow(isSelected: isOpen, isEnabled: isEnabled, agent: nil, action: action) {
            HStack(spacing: 8) {
                icon.image
                    .font(.system(size: 14))
                    .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            }
        } trailing: {
            EmptyView()
        } commands: {
            EmptyView()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) {
            if isEnabled { action() }
        }
    }
}

/// The top of the list: its title, and the menu that groups and sorts it, whose
/// button lines up with the rows' commands. How many repositories it has is in
/// the title's tooltip rather than beside it, where a number would read like
/// the rows' counts of uncommitted files (decision 84).
private struct ListHeader<Trailing: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .help("\(count.formatted()) \(count == 1 ? "repository" : "repositories")")
                .accessibilityValue(count.formatted())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 32)
    }
}

/// A group's label, small and gray, in the middle of a line across the list,
/// which separates one organization's repositories from the next. A chevron
/// after it shows while the pointer is over it, and clicking it collapses or
/// expands the group. A collapsed group's label has the mark of the most
/// urgent agent among the worktrees it hides, in the column of the rows'
/// marks, so that one waiting for you still shows. It has no commands, so the
/// mark stays on hover. The marks' preview in Settings and setup draws one
/// too, over the rows it shows.
struct GroupLabel: View {
    let title: String
    let isCollapsed: Bool
    let agents: RowAgents?
    let toggle: () -> Void
    @State private var isHovering = false

    /// How wide a row's mark is (`SidebarRow.markWidth`).
    private static let markWidth: CGFloat = 24
    /// How wide the chevron is (`Chevron`).
    private static let chevronWidth: CGFloat = 10

    var body: some View {
        let agent = agents?.summary
        HStack(spacing: 8) {
            rule
            HStack(spacing: 4) {
                // As wide as the chevron after the name, so that the name is
                // in the middle whether or not the chevron shows.
                Color.clear
                    .frame(width: Self.chevronWidth, height: 1)
                FadingText(title)
                    .font(.system(size: 12, weight: .medium))
                Chevron(pointsDown: !isCollapsed)
                    .opacity(isHovering ? 1 : 0)
            }
            .layoutPriority(1)
            // The two sides share what's left equally, the mark included, so
            // the lines are as long as each other.
            HStack(spacing: 6) {
                rule
                if let agent {
                    SidebarMark(summary: agent)
                        .frame(width: Self.markWidth)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        // As far in as the rows' text on the left, or as the rows' marks when
        // there's one.
        .padding(.trailing, agent == nil ? 10 : 4)
        .frame(height: 24)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([isCollapsed ? "Collapsed" : "Expanded", agent?.description].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityAction(.default, toggle)
    }

    /// The line on either side of the name, in the color of the one under the
    /// sidebar's commands. It's never shorter than a dash, however long the
    /// name.
    private var rule: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(minWidth: 8, maxWidth: .infinity)
            .frame(height: 1)
    }
}

/// A row in the sidebar, as tall as in the Claude app's sidebar, which the
/// wireframe follows. It fills with gray while the pointer is over it, and a
/// little darker while it's selected. The commands show while the pointer is
/// over it: 24-point buttons 4 points from the row's top and right edges.
///
/// An agent's mark sits at the right edge, in a box as wide as a command's
/// button, and the menu's button covers it on hover (decisions 41 and 58). The
/// row's second line still says what the agent is doing. The label, such as
/// the count, sits just before that box, which every row keeps whether or not
/// it has a mark, so that the counts line up and the pointer never hides one.
/// In a narrow row, the label and the mark's box keep their width and the
/// row's own text gives way, as the counts stay in the title row.
///
/// While there's something to say, the row grows a second line under its own
/// text, and is 52 points tall rather than 32 (decisions 48 and 51). The first
/// line stays where it is in a 32-point row, and the second starts 28 points
/// down, where its own text does. Its words run toward the right edge and fade
/// out before how long, which ends under the mark.
struct SidebarRow<Content: View, Trailing: View, Commands: View>: View {
    var isSelected = false
    /// Whether it does anything. A row that doesn't is dimmed, and shows no
    /// commands on hover.
    var isEnabled = true
    /// Whether clicking it selects it. A row that can't be selected but is
    /// enabled still fills and shows its commands on hover, as a worktree whose
    /// folder is missing does, for its menu.
    var canSelect = true
    /// What agents are doing in the row's worktrees, or nil for no mark.
    var agent: AgentSummary?
    /// What the row's worktree stopped partway through, if it did.
    var unfinished: UnfinishedWork?
    /// What would go wrong with a commit because of who it goes out as, for a
    /// repository's row.
    var identityProblem: CommitIdentity.Problem?
    /// How far along a clone of the row's repository is, while git makes it.
    var cloning: CloneLine?
    /// How far the second line stands from the row's content, to start where
    /// the row's own text does.
    var lineIndent: CGFloat = 0
    let action: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var commands: Commands
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    /// How tall a row is with one line, and with two.
    static var height: CGFloat { 32 }
    static var twoLineHeight: CGFloat { 52 }
    /// How far down the second line starts.
    static var secondLineTop: CGFloat { 28 }
    /// How wide an agent's mark is, with the room around it: the width of a
    /// command's button, which takes its place on hover.
    static var markWidth: CGFloat { 24 }

    init(
        isSelected: Bool = false,
        isEnabled: Bool = true,
        canSelect: Bool = true,
        agent: AgentSummary?,
        unfinished: UnfinishedWork? = nil,
        identityProblem: CommitIdentity.Problem? = nil,
        cloning: CloneLine? = nil,
        lineIndent: CGFloat = 0,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder commands: () -> Commands
    ) {
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.canSelect = canSelect
        self.agent = agent
        self.unfinished = unfinished
        self.identityProblem = identityProblem
        self.cloning = cloning
        self.lineIndent = lineIndent
        self.action = action
        self.content = content()
        self.trailing = trailing()
        self.commands = commands()
    }

    var body: some View {
        let line = RowLine(agent: agent, unfinished: unfinished, identity: identityProblem, cloning: cloning)
        // A row without commands, such as the one for hidden worktrees, keeps
        // its mark on hover.
        let showsCommands = isHovering && isEnabled && Commands.self != EmptyView.self
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                content
                    .frame(maxHeight: .infinity)
                Spacer(minLength: 6)
                HStack(spacing: 0) {
                    HStack(spacing: 0) { trailing }
                    ZStack(alignment: .trailing) {
                        Color.clear
                            .frame(width: Self.markWidth, height: 0)
                        if let agent {
                            SidebarMark(summary: agent)
                                .frame(width: Self.markWidth)
                                .opacity(showsCommands ? 0 : 1)
                        }
                        if showsCommands {
                            HStack(spacing: 0) { commands }
                        }
                    }
                }
                // The label and the mark's place keep their width, so that a
                // narrow row cuts the branch's name short rather than a count.
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: 24)
                .padding(.top, 4)
            }
            .frame(height: Self.height)
            if let line {
                RowLineView(line: line)
                    .frame(maxWidth: .infinity, maxHeight: 16, alignment: .leading)
                    .padding(.leading, lineIndent)
                    // How long ends under the mark.
                    .padding(.trailing, 7)
                    .padding(.top, Self.secondLineTop - Self.height)
                    .transition(SidebarMotion.words(reducesMotion))
            }
        }
        // The line fades in, inside the frame below, so that the row still
        // takes its new height at once (decision 48). It goes at once, since
        // the row is short again and fading words would hang over the next.
        .animation(line == nil ? nil : SidebarMotion.arrival(reducesMotion), value: line == nil)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: line == nil ? Self.height : Self.twoLineHeight, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Palette.selection : isHovering && isEnabled ? Palette.hover : .clear)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture {
            if isEnabled && canSelect { action() }
        }
        .onHover { isHovering = $0 }
    }
}

/// What a sidebar row's second line is about, when it has one (decision 48).
/// An agent that waits for you comes first, because it can't go on without
/// you. Then a merge, rebase or revert that stopped partway, then an agent at
/// work or one that finished, and last a commit that would go wrong because of
/// who it goes out as (decision 103), which stays until the config is fixed. A
/// repository that's being cloned has nothing else to say, so its clone's
/// progress is all its line shows (decision 113). A row with none of these has
/// one line.
enum RowLine: Equatable {
    case agent(AgentSummary)
    case unfinished(UnfinishedWork)
    case identity(CommitIdentity.Problem)
    case cloning(CloneLine)

    init?(agent: AgentSummary?, unfinished: UnfinishedWork?, identity: CommitIdentity.Problem? = nil, cloning: CloneLine? = nil) {
        if let cloning {
            self = .cloning(cloning)
        } else if let agent, case .waiting = agent.state {
            self = .agent(agent)
        } else if let unfinished {
            self = .unfinished(unfinished)
        } else if let agent {
            self = .agent(agent)
        } else if let identity {
            self = .identity(identity)
        } else {
            return nil
        }
    }
}

/// A row's second line, at 13 points, in two parts (decision 51). Its words
/// start under the row's own text and fade out where they don't fit, before
/// the short part at the right: how long an agent has been at it, or how far
/// along stopped work is. An agent's is amber while the agent waits for you,
/// and its tooltip is the mark's. Stopped work is red while there are
/// conflicts.
private struct RowLineView: View {
    let line: RowLine
    @Environment(\.sidebarPictureDate) private var pictureDate

    var body: some View {
        switch line {
        case .agent(let summary):
            TimelineView(WholeMinutes(of: [summary])) { context in
                let parts = summary.rowParts(now: pictureDate ?? context.date)
                Self.parts(words: parts.words, end: parts.time)
                    .foregroundStyle(Self.isWaiting(summary) ? AnyShapeStyle(AgentColors.warn) : AnyShapeStyle(.secondary))
                    .help(summary.help(now: pictureDate ?? context.date))
            }
        case .unfinished(let unfinished):
            let parts = unfinished.rowParts
            Self.parts(words: parts.words, end: parts.end)
                .foregroundStyle(unfinished.hasConflicts ? AnyShapeStyle(Palette.red) : AnyShapeStyle(.secondary))
                .help(unfinished.help)
        case .identity(let problem):
            HStack(spacing: 4) {
                Icon.warning.image
                    .font(.system(size: 11 / 1.128, weight: .semibold))
                FadingText(IdentityWords.rowWords(problem))
                    .font(.system(size: 13))
            }
            .foregroundStyle(AgentColors.warn)
            .help(IdentityWords.problem(problem).detail)
        case .cloning(let cloning):
            Self.parts(words: cloning.words, end: cloning.end)
                .foregroundStyle(.secondary)
                .help(cloning.help)
        }
    }

    private static func parts(words: String, end: String?) -> some View {
        HStack(spacing: 0) {
            FadingText(words)
            Spacer(minLength: 8)
            if let end {
                Text(end)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.system(size: 13))
    }

    private static func isWaiting(_ summary: AgentSummary) -> Bool {
        if case .waiting = summary.state { true } else { false }
    }
}

/// The part of the line under a repository's row that a row under it draws:
/// straight down past the row, or for the last one, around a corner toward the
/// row's first line, which is the middle of a one-line row (decision 48). Each
/// row also draws the gap above it, since a row drawn later would cover
/// anything the one above drew over it.
struct WorktreeConnector: View {
    let isLast: Bool
    /// How far the row's text stands from the row's content, to clear the line.
    static let textIndent: CGFloat = 20

    var body: some View {
        Line(isLast: isLast)
            .stroke(Color.primary.opacity(0.25), lineWidth: 1)
            .allowsHitTesting(false)
    }

    private nonisolated struct Line: Shape {
        let isLast: Bool

        func path(in rect: CGRect) -> Path {
            // On half points, so that a line one point wide stays sharp.
            let x: CGFloat = 14.5
            let rowSpacing: CGFloat = 2
            var path = Path()
            path.move(to: CGPoint(x: x, y: rect.minY - rowSpacing))
            if isLast {
                let middle = (rect.minY + 16).rounded(.down) + 0.5
                path.addArc(tangent1End: CGPoint(x: x, y: middle), tangent2End: CGPoint(x: x + 10, y: middle), radius: 6)
                path.addLine(to: CGPoint(x: x + 10, y: middle))
            } else {
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            return path
        }
    }
}

/// The button that opens the menu of a row's commands, which shows while the
/// pointer is over the row.
private struct RowMenu: View {
    let entries: [RefMenu.Entry]

    var body: some View {
        HoverIcon(size: 24) { Icon.ellipsis.image }
            .overlay { RefMenuArea(entries: entries, opensOnClick: true) }
            .help("More")
        .accessibilityLabel("More")
    }
}

/// A repository's row, which selects its main worktree. The chevron after its
/// name shows or hides its linked worktrees.
///
/// While worktrees have no rows (decision 95), it stands for all of them: it
/// has no chevron, its count adds up their files, and its mark and second line
/// are for the most urgent of them.
private struct RepositoryRow: View {
    let repository: ListedRepository
    let list: RepositoryList
    let title: String
    let detail: String?
    let standsForWorktrees: Bool
    let isSelected: Bool
    /// Whether its popover for a new worktree is open, which keeps the row's
    /// gray to say where the popover came from, as Add Repositories' row does.
    let isOpen: Bool
    let agents: RowAgents?
    let select: () -> Void
    let toggle: () -> Void
    let openInNewWindow: () -> Void
    let locate: () -> Void
    let newWorktree: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        let agent = agents?.summary
        let hasChevron = linkedWorktrees > 0 && !standsForWorktrees
        let identity = self.identity
        let cloning = repository.cloning.map(CloneLine.init(job:))
        SidebarRow(isSelected: isSelected || isOpen, canSelect: cloning == nil, agent: agent, unfinished: unfinished, identityProblem: identity?.problem, cloning: cloning, action: select) {
            HStack(spacing: 3) {
                FadingText(title)
                    .font(.system(size: 13))
                    .layoutPriority(1)
                if hasChevron {
                    Button(action: toggle) {
                        Chevron(pointsDown: repository.isExpanded)
                    }
                    .buttonStyle(.icon(size: 18))
                    .help(repository.isExpanded ? "Hide Worktrees" : "Show Worktrees")
                    .transition(SidebarMotion.words(reducesMotion))
                }
                if let detail {
                    FadingText(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 3)
                        .transition(SidebarMotion.words(reducesMotion))
                }
            }
            // The branch and the chevron come once the repository opens.
            .animation(SidebarMotion.arrival(reducesMotion), value: detail)
            .animation(SidebarMotion.arrival(reducesMotion), value: hasChevron)
            .opacity(problem != nil ? 0.6 : isLoading ? SidebarMotion.loadingOpacity : 1)
            .animation(SidebarMotion.brightening(reducesMotion), value: isLoading)
        } trailing: {
            HStack(spacing: 6) {
                // Before the count, where the eye looks for what's unusual
                // about a repository (decisions 103 and 105).
                if case .someoneElse(let someone) = identity {
                    IdentityPerson(look: .init(identity), style: .inline)
                        .help(IdentityWords(identity: someone).tooltip)
                        .transition(SidebarMotion.label(reducesMotion))
                }
                RowLabel(words: problem, count: ownUncommittedFiles, hasConflicts: ownHasConflicts, failure: ownStatusFailure)
            }
            .animation(SidebarMotion.arrival(reducesMotion), value: identity?.someoneElse)
        } commands: {
            RowMenu(entries: menu)
        }
        .overlay { RefMenuArea(entries: menu) }
        .help(repository.folder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            [detail, cloning?.spoken, linkedWorktreesDescription, unfinished?.title, agent?.description, uncommittedFilesDescription(ownUncommittedFiles, hasConflicts: ownHasConflicts), ownStatusFailure?.spoken, identity.map(IdentityWords.spoken), linkedWorktrees > 0 && !standsForWorktrees ? (repository.isExpanded ? "Expanded" : "Collapsed") : nil, problem]
                .compactMap(\.self)
                .joined(separator: ", ")
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) {
            if cloning == nil { select() }
        }
        .accessibilityActions {
            if linkedWorktrees > 0, !standsForWorktrees {
                Button(repository.isExpanded ? "Hide Worktrees" : "Show Worktrees", action: toggle)
            }
            refMenuActions(menu)
        }
    }

    /// How many worktrees the repository has besides the main one.
    private var linkedWorktrees: Int {
        repository.worktrees.count { !$0.isMain }
    }

    /// The worktrees the row counts: its own, the main one, while the rows under
    /// it count theirs, or all of them while there are no rows under it.
    private var countedWorktrees: [Worktree] {
        standsForWorktrees ? repository.worktrees : Array(repository.worktrees.prefix(1))
    }

    private var ownUncommittedFiles: Int {
        countedWorktrees.reduce(0) { $0 + (repository.uncommittedFiles[$1.path] ?? 0) }
    }

    private var ownHasConflicts: Bool {
        countedWorktrees.contains { repository.conflictedWorktrees.contains($0.path) }
    }

    private var ownStatusFailure: StatusFailureNote? {
        guard standsForWorktrees, repository.worktrees.count > 1 else {
            return .worktree(repository.worktrees.first.flatMap { repository.statusFailures[$0.path] })
        }
        return .hidden(countedWorktrees.count { repository.statusFailures[$0.path] != nil })
    }

    /// What the main worktree stopped partway through, if it did. While the row
    /// stands for every worktree, one stopped on conflicts comes first.
    private var unfinished: UnfinishedWork? {
        let stopped = countedWorktrees.compactMap { repository.unfinishedWork[$0.path] }
        return stopped.first(where: \.hasConflicts) ?? stopped.first
    }

    private var linkedWorktreesDescription: String? {
        switch linkedWorktrees {
        case 0: nil
        case 1: "1 linked worktree"
        case let count: "\(count) linked worktrees"
        }
    }

    /// The main worktree, or the bare repository's entry, once the
    /// repository is open.
    private var main: Worktree? {
        repository.session == nil ? nil : repository.worktrees.first
    }

    private var problem: String? {
        switch repository.state {
        case .opening, .open, .cloning: nil
        case .missing: "Missing"
        case .failed: "Can't open"
        }
    }

    /// What the row says about who the repository's commits go out as: a
    /// tinted person for someone other than the global identity, or a second line
    /// when a commit would go wrong. A bare repository says nothing, since
    /// nothing is committed in it.
    private var identity: IdentityException? {
        guard repository.worktrees.first?.isBare != true else { return nil }
        return IdentityException(repository.identity, defaultIdentity: list.defaultIdentity)
    }

    /// Whether the row is still waiting for its count, which a repository
    /// that can't be opened never gets.
    private var isLoading: Bool {
        problem == nil && !repository.hasCounted
    }

    private var menu: [RefMenu.Entry] {
        if repository.cloning != nil {
            return SidebarMenus.entries(forCloning: repository.cloning?.isCancelling == true) { [list, repository] in
                list.cancelClone(repository)
            }
        }
        return SidebarMenus.entries(
            forRepository: main,
            cantOpen: problem != nil,
            actions: SidebarMenus.RepositoryActions(
                openInNewWindow: openInNewWindow,
                newWorktree: newWorktree,
                locate: locate,
                remove: { [list, repository] in list.remove(repository) },
                reveal: reveal,
                openInTerminal: openInTerminal
            )
        )
    }
}

/// A linked worktree's branch, under its repository with a line to it. Its
/// tooltip has its folder.
///
/// One whose folder is missing can't be selected, and its branch is dimmed, as a
/// missing repository's name is. On hover it shows its menu's button, which is
/// where to find the folder or delete the worktree.
private struct WorktreeRow: View {
    let worktree: Worktree
    let uncommittedFiles: Int
    let hasConflicts: Bool
    let statusFailure: StatusFailureNote?
    /// What the worktree stopped partway through, if it did.
    let unfinished: UnfinishedWork?
    /// Whether its repository's files haven't been counted yet.
    let isLoading: Bool
    let isDeleting: Bool
    let isSelected: Bool
    /// Whether its popover for a new worktree is open.
    let isOpen: Bool
    let isLast: Bool
    let agents: RowAgents?
    let select: () -> Void
    let openInNewWindow: () -> Void
    let newWorktree: () -> Void
    let locate: () -> Void
    let delete: () -> Void
    let unlock: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        let agent = agents?.summary
        SidebarRow(isSelected: isSelected || isOpen, isEnabled: !isDeleting, canSelect: canSelect, agent: agent, unfinished: unfinished, lineIndent: WorktreeConnector.textIndent, action: select) {
            FadingText(worktree.title)
                .font(.system(size: 13))
                .opacity(worktree.isPrunable ? 0.6 : isLoading ? SidebarMotion.loadingOpacity : 1)
                .animation(SidebarMotion.brightening(reducesMotion), value: isLoading)
                .padding(.leading, WorktreeConnector.textIndent)
        } trailing: {
            RowLabel(
                words: isDeleting ? "Deleting…" : worktree.isPrunable ? "Folder missing" : nil,
                count: uncommittedFiles,
                hasConflicts: hasConflicts,
                failure: statusFailure,
                lock: worktree.lockHelp
            )
        } commands: {
            RowMenu(entries: menu)
        }
        .overlay { WorktreeConnector(isLast: isLast) }
        .overlay { RefMenuArea(entries: menu) }
        .help(worktree.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(worktree.title)
        .accessibilityValue([subtitle, unfinished?.title, agent?.description, worktree.isLocked ? "Locked" : nil, uncommittedFilesDescription(uncommittedFiles, hasConflicts: hasConflicts), statusFailure?.spoken].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) {
            if canSelect { select() }
        }
        .accessibilityActions {
            refMenuActions(menu)
        }
    }

    private var canSelect: Bool {
        !worktree.isPrunable && !isDeleting
    }

    private var subtitle: String {
        worktree.isPrunable ? "Its folder is missing" : (worktree.path as NSString).lastPathComponent
    }

    private var menu: [RefMenu.Entry] {
        SidebarMenus.entries(
            forWorktree: worktree,
            isDeleting: isDeleting,
            actions: SidebarMenus.WorktreeActions(
                openInNewWindow: openInNewWindow,
                newWorktree: newWorktree,
                locate: locate,
                delete: delete,
                unlock: unlock,
                reveal: reveal,
                openInTerminal: openInTerminal
            )
        )
    }
}

/// The row under a collapsed repository that stands for the worktrees it
/// hides, and shows them. Its mark is the most urgent of theirs, and stays on
/// hover, since the row has no commands.
private struct HiddenWorktreesRow: View {
    let title: String
    let uncommittedFiles: Int
    let hasConflicts: Bool
    let statusFailure: StatusFailureNote?
    let agents: RowAgents?
    let show: () -> Void

    var body: some View {
        let agent = agents?.summary
        SidebarRow(agent: agent, lineIndent: WorktreeConnector.textIndent, action: show) {
            FadingText(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.leading, WorktreeConnector.textIndent)
        } trailing: {
            RowLabel(count: uncommittedFiles, hasConflicts: hasConflicts, failure: statusFailure)
        } commands: {
            EmptyView()
        }
        .overlay { WorktreeConnector(isLast: true) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([agent?.description, uncommittedFilesDescription(uncommittedFiles, hasConflicts: hasConflicts), statusFailure?.spoken].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, show)
    }
}

/// Hides or shows the sidebar. It's a plain icon like the sidebar's other
/// buttons, rather than the glass button macOS puts in the toolbar.
struct SidebarToggle: View {
    @Binding var visibility: NavigationSplitViewVisibility

    var body: some View {
        Button {
            visibility.toggleSidebar()
        } label: {
            Icon.panelLeft.image
        }
        .buttonStyle(.icon)
        .help(visibility.sidebarCommandTitle)
        .accessibilityLabel(visibility.sidebarCommandTitle)
    }
}

extension NavigationSplitViewVisibility {
    /// What the button and the View menu call hiding or showing the
    /// sidebar. Both change the window's visibility, rather than the menu
    /// collapsing the split view behind SwiftUI's back as `SidebarCommands`
    /// does, which leaves the button's state and the menu's title wrong.
    var sidebarCommandTitle: String {
        self == .detailOnly ? "Show Sidebar" : "Hide Sidebar"
    }

    mutating func toggleSidebar() {
        let next: Self = self == .detailOnly ? .all : .detailOnly
        withAnimation { self = next }
    }
}

extension EnvironmentValues {
    /// The moment a picture of the sidebar stands at, such as the marks'
    /// preview in Settings. Its rows and their tooltips say how long an agent
    /// has been at it as of this moment, so the picture doesn't change while
    /// it's open. Nil in the sidebar itself, whose rows go by the time now.
    @Entry var sidebarPictureDate: Date? = nil
}

extension FocusedValues {
    /// Whether the focused window shows its sidebar, for the View menu.
    @Entry var sidebarVisibility: Binding<NavigationSplitViewVisibility>?
    /// What asks to delete the worktree selected in the sidebar, while the keyboard is
    /// in the sidebar. Anywhere else Command-Delete has to stay what it is in text.
    @Entry var deleteSelectedWorktree: (() -> Void)?
}

/// What a row says just before its mark's place: words about the row itself,
/// such as Missing or Deleting…, or else a gray lock for a locked worktree and
/// its count. Whatever comes, as when a look finishes counting, comes in where
/// it goes rather than appearing at once, and a count that changes rolls to its
/// new number (decision 99).
private struct RowLabel: View {
    var words: String?
    let count: Int
    let hasConflicts: Bool
    let failure: StatusFailureNote?
    /// The lock's tooltip, for a locked worktree.
    var lock: String?
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    /// Everything it shows, which it animates the changes of.
    private struct Shown: Equatable {
        var words: String?
        var count: Int
        var hasConflicts: Bool
        var failure: StatusFailureNote?
        var isLocked: Bool
    }

    var body: some View {
        let hasCount = count > 0 || failure != nil
        HStack(spacing: 0) {
            if let words {
                Text(words)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 7)
                    .transition(SidebarMotion.label(reducesMotion))
            } else {
                if let lock {
                    Icon.lock.image
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, hasCount ? 5 : 7)
                        .help(lock)
                        .transition(SidebarMotion.label(reducesMotion))
                }
                if hasCount {
                    UncommittedCount(count: count, hasConflicts: hasConflicts, failure: failure)
                        .transition(SidebarMotion.label(reducesMotion))
                }
            }
        }
        .animation(SidebarMotion.arrival(reducesMotion), value: Shown(words: words, count: count, hasConflicts: hasConflicts, failure: failure, isLocked: lock != nil))
    }
}

/// How the sidebar takes in what loads after its rows show (decision 99). The
/// names of the saved repositories show at once, and each row fills in as git
/// answers: its branch when the repository opens, then its count. A row's
/// name is faint until its count is in, and then comes up to full strength.
/// What arrives comes in softly where it goes, out of a slight blur, rather
/// than appearing at once, so that a list filling in reads as one settling
/// motion rather than a run of jumps. Someone who asked for less motion gets
/// fades instead.
enum SidebarMotion {
    /// How strong a row's name is while its count isn't in yet.
    static let loadingOpacity = 0.45

    /// What a count, a branch's name or a second line animates with as it
    /// comes in.
    static func arrival(_ reducesMotion: Bool) -> Animation {
        reducesMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.4)
    }

    /// What a faint name animates with as it comes up to full strength, a
    /// little slower than its count arrives, so that the row settles after it.
    static func brightening(_ reducesMotion: Bool) -> Animation {
        .easeOut(duration: reducesMotion ? 0.2 : 0.55)
    }

    /// What rows that loading inserts or moves animate with, or nil to place
    /// them at once.
    static func movement(_ reducesMotion: Bool) -> Animation? {
        reducesMotion ? nil : .smooth(duration: 0.35)
    }

    /// A count or a label grows to its size from its right end, which stays
    /// where it is, as it comes into focus. One that goes only fades, since
    /// the row is done with it.
    static func label(_ reducesMotion: Bool) -> AnyTransition {
        guard !reducesMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: Softened(amount: 1, smallest: 0.6), identity: Softened(amount: 0, smallest: 0.6)),
            removal: .modifier(active: Softened(amount: 1), identity: Softened(amount: 0))
        )
    }

    /// Words, such as a branch's name or a second line, come into focus where
    /// they are. Growing would move them along the line they're on.
    static func words(_ reducesMotion: Bool) -> AnyTransition {
        guard !reducesMotion else { return .opacity }
        return .modifier(active: Softened(amount: 1), identity: Softened(amount: 0))
    }
}

/// Something on its way in or out: faded, blurred, and smaller toward its
/// right end, by `amount`, from none to all the way.
private struct Softened: ViewModifier {
    let amount: Double
    /// How small it gets at its smallest. 1 doesn't grow it at all.
    var smallest: Double = 1
    /// How far its blur spreads at its most, in points.
    private static let blur: CGFloat = 3

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - (1 - smallest) * amount, anchor: .trailing)
            .blur(radius: Self.blur * amount)
            .opacity(1 - amount)
    }
}

/// The repositories that are still loading: the ones that aren't open yet,
/// and the ones whose files haven't been counted yet. The list animates what
/// changes along with these, so that the rows a repository brings when it
/// opens, such as its worktrees, come in, and rows that move because of what
/// it found, as when the list is sorted by uncommitted changes, slide to their
/// places. Removing a repository that has loaded leaves both alone, so it
/// still happens at once, like anything else someone does to the list.
private struct LoadProgress: Equatable {
    var unopened: Set<String> = []
    var uncounted: Set<String> = []

    init(_ repositories: [ListedRepository]) {
        for repository in repositories {
            if repository.session == nil { unopened.insert(repository.path) }
            if !repository.hasCounted { uncounted.insert(repository.path) }
        }
    }
}

/// How many files a row's worktrees have uncommitted, in orange, or in red with a
/// triangle when some of them have conflicts, so that a stuck worktree shows
/// without selecting it (decision 28).
///
/// A worktree whose files git can't list has a triangle too, in orange, so
/// that it doesn't pass for one with nothing to commit. Its tooltip says what
/// git said. The count leaves that worktree out, and there's no number when
/// it's the row's only one.
struct UncommittedCount: View {
    let count: Int
    let hasConflicts: Bool
    var failure: StatusFailureNote?
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        if let failure {
            label.help(failure.help)
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 3) {
            if hasConflicts || failure != nil {
                Icon.warning.image
            }
            if count > 0 || failure == nil {
                // A new number rolls in, up or down as the count went, when
                // what draws the count animates it, as `RowLabel` does.
                Text(count, format: .number)
                    .contentTransition(reducesMotion ? .opacity : .numericText(value: Double(count)))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(hasConflicts ? Palette.red : Color.orange)
        .padding(.trailing, 7)
    }
}

/// What a sidebar row says about worktrees whose uncommitted files git
/// couldn't list: for one worktree, what git said, and for the row of hidden
/// worktrees, how many of them.
struct StatusFailureNote: Equatable {
    /// The tooltip of the row's triangle.
    var help: String
    /// What VoiceOver reads among the row's other facts.
    var spoken: String

    static func worktree(_ message: String?) -> Self? {
        message.map { Self(help: "\(RepositoryModel.statusFailureTitle): \($0)", spoken: "can't list uncommitted files") }
    }

    static func hidden(_ count: Int) -> Self? {
        guard count > 0 else { return nil }
        let which = count == 1 ? "1 of these worktrees" : "\(count) of these worktrees"
        return Self(help: "\(RepositoryModel.statusFailureTitle) in \(which).", spoken: "can't list uncommitted files in \(which)")
    }
}

/// Whether the person uses agents, as Settings › Agents turns them on, for the
/// views that say what agents are doing: the sidebar's rows and the worktree
/// menu. While agents are off, neither says anything about them, so that
/// nothing shows what the person turned off (decisions 41 and 89).
///
/// Both views read it through this, rather than each keeping the key, so that
/// they can't come to disagree, and so that tests can give it defaults of
/// their own.
struct AgentMarksSetting: DynamicProperty {
    @AppStorage private var usesAgents: Bool

    /// - Parameter store: Where the choice is kept. Nil is the view's
    ///   `defaultAppStorage`, which is the standard defaults unless something
    ///   sets others.
    init(store: UserDefaults? = nil) {
        _usesAgents = AppStorage(wrappedValue: true, AgentPreferences.usesAgentsKey, store: store)
    }

    /// The monitor while agents are on, or nil while they're turned off.
    func monitor(_ monitor: AgentMonitor) -> AgentMonitor? {
        usesAgents ? monitor : nil
    }
}

/// Where a row finds what agents are doing in the worktrees it stands for.
///
/// Each row asks in its own body, rather than the list asking for all of them,
/// so that a mark changing redraws the rows and leaves the list, which would
/// lay out every row again, alone.
struct RowAgents {
    let monitor: AgentMonitor
    let list: RepositoryList
    /// The folders of the worktrees the row stands for.
    let worktrees: [String]

    var summary: AgentSummary? {
        monitor.summary(forWorktrees: worktrees, in: list)
    }
}

/// A row's mark for its agents, with a tooltip that says what they're doing
/// and, from a minute on, for how long, as in "Claude Code is working, for 6
/// minutes". It redraws as that reaches another minute, and not in between.
struct SidebarMark: View {
    let summary: AgentSummary
    @Environment(\.sidebarPictureDate) private var pictureDate

    var body: some View {
        TimelineView(minutes) { context in
            // The canvas draws marks 14 points wide, which is AgentMark's size.
            AgentMark(state: summary.state)
                .help(summary.help(now: pictureDate ?? context.date))
        }
    }

    /// When the tooltip changes. A finished mark's never does.
    var minutes: WholeMinutes {
        WholeMinutes(of: [summary])
    }
}

/// The moments when an agent that has been doing something since one of these
/// dates has been at it for another whole minute, which is when what says for
/// how long changes. Each comes a second after the minute, so that rounding
/// can't leave the count a minute short.
nonisolated struct WholeMinutes: TimelineSchedule, Equatable {
    var since: [Date]

    private static let margin: TimeInterval = 1

    init(since: [Date]) {
        self.since = since
    }

    /// The minutes of those of these agents that say for how long they've
    /// been at it, which are the ones working or waiting. A finished one says
    /// no time, so it has none, and nothing redraws for it.
    @MainActor init(of agents: [AgentSummary?]) {
        since = agents.compactMap { agent in
            agent.flatMap { $0.state == .finished ? nil : $0.since }
        }
    }

    func entries(from start: Date, mode: TimelineScheduleMode) -> UnfoldFirstSequence<Date> {
        sequence(first: start) { [since] date in
            since.map { begun in
                let minutes = ((date.timeIntervalSince(begun) - Self.margin) / 60).rounded(.down)
                return begun.addingTimeInterval(max(1, minutes + 1) * 60 + Self.margin)
            }.min()
        }
    }
}

private func uncommittedFilesDescription(_ count: Int, hasConflicts: Bool = false) -> String? {
    let conflicts = hasConflicts ? ", with conflicts" : ""
    return switch count {
    case 0: nil
    case 1: "1 uncommitted file\(conflicts)"
    default: "\(count) uncommitted files\(conflicts)"
    }
}

func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
}

extension Worktree {
    /// What the sidebar calls the worktree: its branch, or the commit its
    /// detached `HEAD` is at.
    var title: String {
        if isBare { return "bare repository" }
        if let branch { return Ref.shortName(branch) }
        if let head { return "detached at " + head.hex.prefix(8) }
        return "HEAD"
    }

    /// The tooltip of a locked worktree's lock, with the reason the lock gives,
    /// or nil when it isn't locked.
    var lockHelp: String? {
        guard isLocked else { return nil }
        return lockReason.map { "Locked: " + $0 } ?? "Locked"
    }

    /// A line of its own for the lock's reason, in a tooltip whose other lines
    /// already say Locked, or nil when there's no reason to give.
    var lockReasonLine: String? {
        guard isLocked, let lockReason else { return nil }
        return "Reason for the lock: " + lockReason
    }
}
