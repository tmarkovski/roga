import AppKit
import GitCore
import IconUI
import MenuUI
import RepositoryEngine
import SwiftUI

/// The window's sidebar: the rail that picks an organization, and the list of
/// its repositories with their worktrees (docs/main-window.md).
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
    /// What the rail has selected. Setting it picks a scope.
    @Binding var scope: SidebarScope
    @Binding var place: SidebarPlace
    let showsRail: Bool
    let locate: (ListedRepository) -> Void
    /// Whether the rows show agents' marks, as the person chose in Settings.
    var marks = AgentMarksSetting()
    @State private var isAddingRepositories = false
    @State private var adding = AddRepositoriesChoices()
    @State private var deletions = WorktreeDeletionModel()
    @FocusState private var isFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let groups = list.groups
        HStack(spacing: 0) {
            if showsRail {
                OrganizationRail(groups: groups, scope: $scope) {
                    addButton(edge: .trailing) { isPresented in
                        RailButton(title: "Add Repositories", isOpen: isPresented, action: { isAddingRepositories = true }) {
                            Icon.plus.image
                                .font(.system(size: 15, weight: .light))
                        }
                    }
                }
                Rectangle()
                    .fill(Palette.separator)
                    .frame(width: 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                ScopeHeader(title: scope == .all ? "All repositories" : groups.title(of: scope), count: groups.repositories(in: scope).count) {
                    if !showsRail {
                        addButton(edge: .bottom) { _ in
                            Button("Add Repositories", icon: .plus) { isAddingRepositories = true }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.icon(size: 24))
                                .help("Add Repositories")
                        }
                    }
                }
                rows(groups: groups)
            }
            .frame(maxWidth: .infinity)
        }
        .dialog { deletions.dialog }
    }

    /// The button for adding repositories, with the popover it opens.
    private func addButton<Label: View>(edge: Edge, @ViewBuilder label: (Bool) -> Label) -> some View {
        label(isAddingRepositories)
            .disabled(!list.isConnected)
            .popover(isPresented: $isAddingRepositories, arrowEdge: edge) {
                AddRepositories(list: list, scope: scope, choices: $adding, lookInAnotherFolder: lookInAnotherFolder) { selection = $0 }
            }
    }

    /// Closes the popover while the open panel is up, because a popover can
    /// close by itself when another window takes over, and reopens it after.
    private func lookInAnotherFolder() {
        isAddingRepositories = false
        Task {
            if let folder = chooseRepositoryFolder(message: "Choose a folder to look in, or a repository.") {
                adding.pickedFolders.append(folder)
            }
            isAddingRepositories = true
        }
    }

    private func rows(groups: RepositoryGroups) -> some View {
        let layout = SidebarLayout(groups: groups, scope: scope, selection: selection, place: place)
        let items = layout.items
        return ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
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
            .onChange(of: scope) {
                if let selection { scroller.scrollTo(selection) }
            }
        }
    }

    @ViewBuilder private func row(_ item: SidebarItem) -> some View {
        switch item {
        case .label(let title):
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 8))
                .accessibilityAddTraits(.isHeader)
        case .repository(let repository, let title, let detail):
            let home = repository.home
            RepositoryRow(repository: repository, list: list, title: title, detail: detail, isSelected: selection == home, agents: agents(of: item)) {
                select(home)
            } toggle: {
                isFocused = true
                list.setExpanded(!repository.isExpanded, repository)
            } openInNewWindow: {
                openWindow(value: WorkspaceWindow(selection: home))
            } locate: {
                locate(repository)
            }
            .id(home)
        case .worktree(let repository, let worktree, let isLast):
            let row = WorktreeSelection(repository: repository.path, worktree: worktree.path)
            WorktreeRow(
                worktree: worktree,
                uncommittedFiles: repository.uncommittedFiles[worktree.path] ?? 0,
                hasConflicts: repository.conflictedWorktrees.contains(worktree.path),
                isDeleting: repository.deletingWorktrees.contains(worktree.path),
                isSelected: selection == row,
                isLast: isLast,
                agents: agents(of: item)
            ) {
                select(row)
            } openInNewWindow: {
                openWindow(value: WorkspaceWindow(selection: row))
            } delete: {
                deletions.askToDelete(worktree, in: repository, list: list)
            }
            .id(row)
        case .hiddenWorktrees(let repository, let title, _, let uncommittedFiles, let hasConflicts):
            HiddenWorktreesRow(title: title, uncommittedFiles: uncommittedFiles, hasConflicts: hasConflicts, agents: agents(of: item)) {
                isFocused = true
                list.setExpanded(true, repository)
            }
        }
    }

    /// Where a row finds what agents are doing in the worktrees it stands for,
    /// or nil while the marks are turned off.
    func agents(of item: SidebarItem) -> RowAgents? {
        marks.monitor(monitor).map { RowAgents(monitor: $0, list: list, worktrees: item.markedWorktrees) }
    }

    private func select(_ row: WorktreeSelection) {
        isFocused = true
        selection = row
    }

    /// The up and down arrows move between the worktrees showing. The right and
    /// left arrows show and hide the linked worktrees of the selected one's
    /// repository.
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
            let index = (rows.firstIndex { $0 == selection } ?? (step > 0 ? -1 : rows.count)) + step
            guard rows.indices.contains(index) else { return .handled }
            select(rows[index])
            scroller.scrollTo(rows[index])
            return .handled
        case .leftArrow, .rightArrow:
            guard let selection, let repository = list.repository(at: selection.repository) else { return .ignored }
            list.setExpanded(key == .rightArrow, repository)
            return .handled
        default:
            return .ignored
        }
    }
}

/// The column that picks which repositories the list shows: All, each
/// organization, Other, and a button for adding repositories at the bottom.
private struct OrganizationRail<Add: View>: View {
    let groups: RepositoryGroups
    @Binding var scope: SidebarScope
    @ViewBuilder var add: Add

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    RailButton(title: groups.title(of: .all), isSelected: scope == .all) { scope = .all } label: {
                        Icon.inbox.image
                            .font(.system(size: 15, weight: .light))
                    }
                    ForEach(groups.organizations) { organization in
                        RailButton(title: organization.name, isSelected: scope == organization.scope) { scope = organization.scope } label: {
                            Monogram(letters: organization.monogram, isSelected: scope == organization.scope)
                        }
                    }
                    if groups.hasOthers {
                        RailButton(title: groups.title(of: .other), isSelected: scope == .other) { scope = .other } label: {
                            Icon.ellipsis.image
                                .font(.system(size: 14))
                        }
                    }
                }
                .padding(.top, 2)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            add
                .padding(.vertical, 10)
        }
        .frame(width: 55)
    }
}

/// The tile that an organization's letters sit on, and that anything selected on
/// the rail sits on in ink (decision 36).
private enum RailTile {
    static let size: CGFloat = 28
    static let cornerRadius = size * 0.26
}

/// An item on the rail. It fills with gray under the pointer, and the selected
/// one is a solid ink tile instead.
private struct RailButton<Label: View>: View {
    let title: String
    var isSelected = false
    /// Whether this button's popover is open, which keeps its gray without
    /// looking like the organization that's selected.
    var isOpen = false
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(isSelected ? AnyShapeStyle(Palette.onInk) : AnyShapeStyle(isOpen || isHovering ? .primary : .secondary))
                .frame(width: 38, height: 38)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: RailTile.cornerRadius, style: .continuous)
                            .fill(Palette.ink)
                            .frame(width: RailTile.size, height: RailTile.size)
                    } else {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isOpen ? Palette.selection : isHovering ? Palette.hover : .clear)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Two letters that stand for an organization, on a gray tile until it's
/// selected, when `RailButton` puts them on ink.
private struct Monogram: View {
    let letters: String
    var isSelected = false

    var body: some View {
        Text(letters)
            .font(.system(size: RailTile.size * 0.4, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(isSelected ? AnyShapeStyle(Palette.onInk) : AnyShapeStyle(.secondary))
            .frame(width: RailTile.size, height: RailTile.size)
            .background {
                if !isSelected {
                    RoundedRectangle(cornerRadius: RailTile.cornerRadius, style: .continuous)
                        .fill(Palette.selection)
                }
            }
    }
}

/// The top of the list: what the rail picked, and how many repositories it has.
private struct ScopeHeader<Trailing: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text(count, format: .number)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 32)
    }
}

/// A row in the sidebar, as tall as in the Claude app's sidebar, which the
/// wireframe follows. It fills with gray while the pointer is over it, and a
/// little darker while it's selected. Its top right corner shows a label,
/// which gives way to the row's commands while the pointer is over it. The
/// commands are 24-point buttons 4 points from the row's top and right edges.
///
/// An agent's mark comes before the label, and stays before the commands on
/// hover, so that what an agent is doing still shows while the pointer is
/// there (decision 41). It's 6 points from what follows it. With nothing after
/// it, those 6 points leave the mark where a count would end. Its box is the
/// same size whatever it shows, so a mark changing never moves anything.
private struct SidebarRow<Content: View, Trailing: View, Commands: View>: View {
    var isSelected = false
    var isEnabled = true
    /// What agents are doing in the row's worktrees, or nil for no mark.
    var agent: AgentSummary?
    let action: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var commands: Commands
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            content
                .frame(maxHeight: .infinity)
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                if let agent {
                    SidebarMark(summary: agent)
                        .padding(.trailing, 6)
                }
                if isHovering && isEnabled {
                    commands
                } else {
                    trailing
                }
            }
            .frame(height: 24)
            .padding(.top, 4)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Palette.selection : isHovering && isEnabled ? Palette.hover : .clear)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture {
            if isEnabled { action() }
        }
        .onHover { isHovering = $0 }
    }
}

/// The part of the line under a repository's row that a row under it draws:
/// straight down past the row, or for the last one, around a corner toward the
/// row's text. Each row also draws the gap above it, since a row drawn later
/// would cover anything the one above drew over it.
private struct WorktreeConnector: View {
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
                let middle = rect.midY.rounded(.down) + 0.5
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
private struct RepositoryRow: View {
    let repository: ListedRepository
    let list: RepositoryList
    let title: String
    let detail: String?
    let isSelected: Bool
    let agents: RowAgents?
    let select: () -> Void
    let toggle: () -> Void
    let openInNewWindow: () -> Void
    let locate: () -> Void

    var body: some View {
        let agent = agents?.summary
        SidebarRow(isSelected: isSelected, agent: agent, action: select) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .layoutPriority(1)
                if linkedWorktrees > 0 {
                    Button(action: toggle) {
                        Chevron(pointsDown: repository.isExpanded)
                    }
                    .buttonStyle(.icon(size: 18))
                    .help(repository.isExpanded ? "Hide Worktrees" : "Show Worktrees")
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 3)
                }
            }
            .opacity(problem == nil ? 1 : 0.6)
        } trailing: {
            if let problem {
                Text(problem)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 7)
            } else if ownUncommittedFiles > 0 {
                UncommittedCount(count: ownUncommittedFiles, hasConflicts: ownHasConflicts)
            }
        } commands: {
            RowMenu(entries: menu)
        }
        .overlay { RefMenuArea(entries: menu) }
        .help(repository.folder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            [detail, linkedWorktreesDescription, agent?.description, uncommittedFilesDescription(ownUncommittedFiles, hasConflicts: ownHasConflicts), linkedWorktrees > 0 ? (repository.isExpanded ? "Expanded" : "Collapsed") : nil, problem]
                .compactMap(\.self)
                .joined(separator: ", ")
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityActions {
            if linkedWorktrees > 0 {
                Button(repository.isExpanded ? "Hide Worktrees" : "Show Worktrees", action: toggle)
            }
            refMenuActions(menu)
        }
    }

    /// How many worktrees the repository has besides the main one.
    private var linkedWorktrees: Int {
        repository.worktrees.count { !$0.isMain }
    }

    /// The row counts its own files, and the rows under it count theirs.
    private var ownUncommittedFiles: Int {
        guard let main = repository.worktrees.first else { return 0 }
        return repository.uncommittedFiles[main.path] ?? 0
    }

    private var ownHasConflicts: Bool {
        repository.worktrees.first.map { repository.conflictedWorktrees.contains($0.path) } ?? false
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
        case .opening, .open: nil
        case .missing: "Missing"
        case .failed: "Can't open"
        }
    }

    private var menu: [RefMenu.Entry] {
        var entries: [RefMenu.Entry] = []
        if let main {
            entries += [
                .command("Open in New Window", action: openInNewWindow),
                .divider,
                .command("Show in Finder") { reveal(main.path) },
                .command("Open in Terminal") { openInTerminal(main.path) },
                .divider,
            ]
        } else if problem != nil {
            entries += [.command("Locate…", action: locate), .divider]
        }
        entries.append(.command("Remove from Sidebar") { list.remove(repository) })
        return entries
    }
}

/// A linked worktree's branch, under its repository with a line to it. Its
/// tooltip has its folder.
private struct WorktreeRow: View {
    let worktree: Worktree
    let uncommittedFiles: Int
    let hasConflicts: Bool
    let isDeleting: Bool
    let isSelected: Bool
    let isLast: Bool
    let agents: RowAgents?
    let select: () -> Void
    let openInNewWindow: () -> Void
    let delete: () -> Void

    var body: some View {
        let agent = agents?.summary
        SidebarRow(isSelected: isSelected, isEnabled: !worktree.isPrunable && !isDeleting, agent: agent, action: select) {
            Text(worktree.title)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, WorktreeConnector.textIndent)
        } trailing: {
            if isDeleting {
                Text("Deleting…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 7)
            } else if worktree.isPrunable {
                Text("Folder missing")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 7)
            } else if uncommittedFiles > 0 {
                UncommittedCount(count: uncommittedFiles, hasConflicts: hasConflicts)
            }
        } commands: {
            commands
        }
        .overlay { WorktreeConnector(isLast: isLast) }
        .overlay { RefMenuArea(entries: menu) }
        .buttonStyle(.icon(size: 24))
        .help(worktree.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(worktree.title)
        .accessibilityValue([subtitle, agent?.description, uncommittedFilesDescription(uncommittedFiles, hasConflicts: hasConflicts)].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityActions {
            refMenuActions(menu)
        }
    }

    @ViewBuilder private var commands: some View {
        Button(action: openInNewWindow) { Icon.newWindow.image }
            .help("Open in New Window")
            .accessibilityLabel("Open in New Window")
        RowMenu(entries: menu)
    }

    private var subtitle: String {
        worktree.isPrunable ? "Its folder is missing" : (worktree.path as NSString).lastPathComponent
    }

    /// Whether it has a branch that can go with it. A branch without commits yet
    /// has nothing to delete.
    private var hasBranch: Bool {
        worktree.branch != nil && worktree.head != nil
    }

    /// Its one deleting row. With a branch that could go too, the dialog asks how far
    /// to go, which the ellipsis says. Without one, it may not ask at all.
    private var menu: [RefMenu.Entry] {
        placeEntries + [
            .divider,
            .command(hasBranch ? "Delete…" : "Delete Worktree", isDestructive: true, isEnabled: !isDeleting, action: delete),
        ]
    }

    private var placeEntries: [RefMenu.Entry] {
        [
            .command("Open in New Window", action: openInNewWindow),
            .divider,
            .command("Show in Finder") { reveal(worktree.path) },
            .command("Open in Terminal") { openInTerminal(worktree.path) },
        ]
    }
}

/// The row under a collapsed repository that stands for the worktrees it
/// hides, and shows them. Its count stays on hover, since it has no commands.
/// Its mark is the most urgent of theirs.
private struct HiddenWorktreesRow: View {
    let title: String
    let uncommittedFiles: Int
    let hasConflicts: Bool
    let agents: RowAgents?
    let show: () -> Void

    var body: some View {
        let agent = agents?.summary
        SidebarRow(agent: agent, action: show) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, WorktreeConnector.textIndent)
        } trailing: {
            count
        } commands: {
            count
        }
        .overlay { WorktreeConnector(isLast: true) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([agent?.description, uncommittedFilesDescription(uncommittedFiles, hasConflicts: hasConflicts)].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, show)
    }

    @ViewBuilder private var count: some View {
        if uncommittedFiles > 0 {
            UncommittedCount(count: uncommittedFiles, hasConflicts: hasConflicts)
        }
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

extension FocusedValues {
    /// Whether the focused window shows its sidebar, for the View menu.
    @Entry var sidebarVisibility: Binding<NavigationSplitViewVisibility>?
    /// What asks to delete the worktree selected in the sidebar, while the keyboard is
    /// in the sidebar. Anywhere else Command-Delete has to stay what it is in text.
    @Entry var deleteSelectedWorktree: (() -> Void)?
}

/// How many files a row's worktrees have uncommitted, in orange, or in red with a
/// triangle when some of them have conflicts, so that a stuck worktree shows
/// without selecting it (decision 28).
private struct UncommittedCount: View {
    let count: Int
    let hasConflicts: Bool

    var body: some View {
        HStack(spacing: 3) {
            if hasConflicts {
                Icon.warning.image
            }
            Text(count, format: .number)
        }
        .font(.system(size: 13))
        .foregroundStyle(hasConflicts ? Palette.red : Color.orange)
        .padding(.trailing, 7)
    }
}

/// Whether the person has agents' marks turned on in Settings, for the views
/// that say what agents are doing: the sidebar's rows and the worktree menu.
/// While the marks are off, neither says anything about agents, so that
/// nothing shows what the person turned off (decision 41).
///
/// Both views read it through this, rather than each keeping the key, so that
/// they can't come to disagree, and so that tests can give it defaults of
/// their own.
struct AgentMarksSetting: DynamicProperty {
    @AppStorage private var showsMarks: Bool

    /// - Parameter store: Where the choice is kept. Nil is the view's
    ///   `defaultAppStorage`, which is the standard defaults unless something
    ///   sets others.
    init(store: UserDefaults? = nil) {
        _showsMarks = AppStorage(wrappedValue: true, AgentPreferences.showsMarksKey, store: store)
    }

    /// The monitor while the marks show, or nil while they're turned off.
    func monitor(_ monitor: AgentMonitor) -> AgentMonitor? {
        showsMarks ? monitor : nil
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

    /// The canvas draws marks 14 points wide.
    private static let size: CGFloat = 14
    /// The circle-alert fills its box, while the ring's outer edge is 13/16 of
    /// it, so the waiting mark is drawn this much smaller to look as big as a
    /// ring on the row beside it. Measured, both are then 0.81 of the box.
    private static let waitingScale: CGFloat = 0.88

    var body: some View {
        TimelineView(minutes) { context in
            AgentMark(state: summary.state, size: isWaiting ? Self.size * Self.waitingScale : Self.size)
                .frame(width: Self.size, height: Self.size)
                .help(summary.help(now: context.date))
        }
    }

    private var isWaiting: Bool {
        if case .waiting = summary.state { true } else { false }
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

func openInTerminal(_ path: String) {
    guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
    NSWorkspace.shared.open([URL(filePath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
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
}
