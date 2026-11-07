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
    /// Whether the window shows Settings, which the gear at the bottom of the
    /// rail opens.
    @Binding var showsSettings: Bool
    let locate: (ListedRepository) -> Void
    /// Shows a worktree and opens New Branch there, with In a new worktree
    /// ticked.
    let newWorktree: (WorktreeSelection) -> Void
    /// Whether the rows show agents' marks, as the person chose in Settings.
    var marks = AgentMarksSetting()
    @State private var isAddingRepositories = false
    @State private var adding = AddRepositoriesChoices()
    @State private var deletions = WorktreeDeletionModel()
    @State private var repairs = WorktreeRepairModel()
    @FocusState private var isFocused: Bool
    @Environment(\.openWindow) private var openWindow
    /// A new version of Roga, which the rail shows above the gear, or the list
    /// at its bottom while the rail is hidden.
    @Environment(Updates.self) private var updates: Updates?

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
                    if let updates, let pending = updates.pending {
                        RailButton(title: pending.title, action: updates.open) {
                            Icon.circleArrowUp.image
                                .font(.system(size: 15))
                                .foregroundStyle(Palette.action)
                        }
                    }
                    // Settings isn't something the list can show, so it keeps
                    // the gray of an open popover while the sheet is up rather
                    // than the ink of what's selected.
                    RailButton(title: "Settings", isOpen: showsSettings, action: { showsSettings = true }) {
                        Icon.settings.image
                            .font(.system(size: 15, weight: .light))
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
                if !showsRail, let updates, let pending = updates.pending {
                    UpdateRow(pending: pending, action: updates.open)
                        .padding(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .dialog { deletions.dialog ?? repairs.dialog }
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
            } newWorktree: {
                newWorktree(home)
            }
            .id(home)
        case .worktree(let repository, let worktree, let isLast):
            let row = WorktreeSelection(repository: repository.path, worktree: worktree.path)
            WorktreeRow(
                worktree: worktree,
                uncommittedFiles: repository.uncommittedFiles[worktree.path] ?? 0,
                hasConflicts: repository.conflictedWorktrees.contains(worktree.path),
                unfinished: repository.unfinishedWork[worktree.path],
                isDeleting: repository.deletingWorktrees.contains(worktree.path),
                isSelected: selection == row,
                isLast: isLast,
                agents: agents(of: item)
            ) {
                select(row)
            } openInNewWindow: {
                openWindow(value: WorkspaceWindow(selection: row))
            } newWorktree: {
                newWorktree(row)
            } locate: {
                repairs.locate(worktree, in: repository, list: list) { select($0) }
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
/// organization and Other, with buttons for adding repositories and for
/// Settings at the bottom.
private struct OrganizationRail<Bottom: View>: View {
    let groups: RepositoryGroups
    @Binding var scope: SidebarScope
    @ViewBuilder var bottom: Bottom

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
            VStack(spacing: 8) {
                bottom
            }
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
/// An agent's mark sits right before the label, in a box as wide as a
/// command's button, and stays there on hover, so that what an agent is doing
/// still shows while the pointer is there (decisions 41 and 51). The label's
/// place is at least that wide while there's a mark, and keeps the width of the
/// wider of the label and the commands, so the mark doesn't move when one gives
/// way to the other, or when the label goes. In a narrow row, the mark and the
/// label keep their width and the row's own text gives way, as the counts stay
/// in the title row.
///
/// While there's something to say, the row grows a second line under its own
/// text, and is 52 points tall rather than 32 (decisions 48 and 51). The first
/// line stays where it is in a 32-point row, and the second starts 28 points
/// down, where its own text does. Its words run toward the right edge and fade
/// out before how long, which ends where a count does, under the mark and the
/// label.
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
    /// How far the second line stands from the row's content, to start where
    /// the row's own text does.
    var lineIndent: CGFloat = 0
    let action: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var commands: Commands
    @State private var isHovering = false

    /// How tall a row is with one line, and with two.
    static var height: CGFloat { 32 }
    static var twoLineHeight: CGFloat { 52 }
    /// How far down the second line starts.
    static var secondLineTop: CGFloat { 28 }
    /// How wide an agent's mark is, with the room around it, and the least the
    /// label takes beside it: the width of a command's button.
    static var markWidth: CGFloat { 24 }

    init(
        isSelected: Bool = false,
        isEnabled: Bool = true,
        canSelect: Bool = true,
        agent: AgentSummary?,
        unfinished: UnfinishedWork? = nil,
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
        self.lineIndent = lineIndent
        self.action = action
        self.content = content()
        self.trailing = trailing()
        self.commands = commands()
    }

    var body: some View {
        let line = RowLine(agent: agent, unfinished: unfinished)
        let showsCommands = isHovering && isEnabled
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                content
                    .frame(maxHeight: .infinity)
                Spacer(minLength: 6)
                HStack(spacing: 0) {
                    if let agent {
                        SidebarMark(summary: agent)
                            .frame(width: Self.markWidth)
                    }
                    ZStack(alignment: .trailing) {
                        Color.clear
                            .frame(width: agent == nil ? 0 : Self.markWidth, height: 0)
                        HStack(spacing: 0) { trailing }
                            .opacity(showsCommands ? 0 : 1)
                        if showsCommands {
                            HStack(spacing: 0) { commands }
                        }
                    }
                }
                // The mark and what follows it keep their width, so that a
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
                    // How long ends where a count does.
                    .padding(.trailing, 7)
                    .padding(.top, Self.secondLineTop - Self.height)
            }
        }
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
/// you. Then a merge, rebase or revert that stopped partway, and last an agent
/// at work or one that finished. A row with none of these has one line.
enum RowLine: Equatable {
    case agent(AgentSummary)
    case unfinished(UnfinishedWork)

    init?(agent: AgentSummary?, unfinished: UnfinishedWork?) {
        if let agent, case .waiting = agent.state {
            self = .agent(agent)
        } else if let unfinished {
            self = .unfinished(unfinished)
        } else if let agent {
            self = .agent(agent)
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

    var body: some View {
        switch line {
        case .agent(let summary):
            TimelineView(WholeMinutes(of: [summary])) { context in
                let parts = summary.rowParts(now: context.date)
                Self.parts(words: parts.words, end: parts.time)
                    .foregroundStyle(Self.isWaiting(summary) ? AnyShapeStyle(AgentColors.warn) : AnyShapeStyle(.secondary))
                    .help(summary.help(now: context.date))
            }
        case .unfinished(let unfinished):
            let parts = unfinished.rowParts
            Self.parts(words: parts.words, end: parts.end)
                .foregroundStyle(unfinished.hasConflicts ? AnyShapeStyle(Palette.red) : AnyShapeStyle(.secondary))
                .help(unfinished.help)
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

/// A new version of Roga, at the bottom of the list while the rail and its
/// gear are hidden, in the brand's orange.
private struct UpdateRow: View {
    let pending: Updates.Pending
    let action: () -> Void

    var body: some View {
        SidebarRow(agent: nil, action: action) {
            HStack(spacing: 8) {
                Icon.circleArrowUp.image
                    .font(.system(size: 14))
                Text(pending.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.action)
        } trailing: {
            EmptyView()
        } commands: {
            EmptyView()
        }
        .help(pending.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pending.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }
}

/// The part of the line under a repository's row that a row under it draws:
/// straight down past the row, or for the last one, around a corner toward the
/// row's first line, which is the middle of a one-line row (decision 48). Each
/// row also draws the gap above it, since a row drawn later would cover
/// anything the one above drew over it.
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
    let newWorktree: () -> Void

    var body: some View {
        let agent = agents?.summary
        SidebarRow(isSelected: isSelected, agent: agent, unfinished: unfinished, action: select) {
            HStack(spacing: 3) {
                FadingText(title)
                    .font(.system(size: 14))
                    .layoutPriority(1)
                if linkedWorktrees > 0 {
                    Button(action: toggle) {
                        Chevron(pointsDown: repository.isExpanded)
                    }
                    .buttonStyle(.icon(size: 18))
                    .help(repository.isExpanded ? "Hide Worktrees" : "Show Worktrees")
                }
                if let detail {
                    FadingText(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
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
            [detail, linkedWorktreesDescription, unfinished?.title, agent?.description, uncommittedFilesDescription(ownUncommittedFiles, hasConflicts: ownHasConflicts), linkedWorktrees > 0 ? (repository.isExpanded ? "Expanded" : "Collapsed") : nil, problem]
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

    /// What the main worktree stopped partway through, if it did.
    private var unfinished: UnfinishedWork? {
        repository.worktrees.first.flatMap { repository.unfinishedWork[$0.path] }
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
        SidebarMenus.entries(
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
    /// What the worktree stopped partway through, if it did.
    let unfinished: UnfinishedWork?
    let isDeleting: Bool
    let isSelected: Bool
    let isLast: Bool
    let agents: RowAgents?
    let select: () -> Void
    let openInNewWindow: () -> Void
    let newWorktree: () -> Void
    let locate: () -> Void
    let delete: () -> Void

    var body: some View {
        let agent = agents?.summary
        SidebarRow(isSelected: isSelected, isEnabled: !isDeleting, canSelect: canSelect, agent: agent, unfinished: unfinished, lineIndent: WorktreeConnector.textIndent, action: select) {
            FadingText(worktree.title)
                .font(.system(size: 14))
                .opacity(worktree.isPrunable ? 0.6 : 1)
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
            RowMenu(entries: menu)
        }
        .overlay { WorktreeConnector(isLast: isLast) }
        .overlay { RefMenuArea(entries: menu) }
        .help(worktree.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(worktree.title)
        .accessibilityValue([subtitle, unfinished?.title, agent?.description, uncommittedFilesDescription(uncommittedFiles, hasConflicts: hasConflicts)].compactMap(\.self).joined(separator: ", "))
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
                reveal: reveal,
                openInTerminal: openInTerminal
            )
        )
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
        SidebarRow(agent: agent, lineIndent: WorktreeConnector.textIndent, action: show) {
            FadingText(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
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

    var body: some View {
        TimelineView(minutes) { context in
            // The canvas draws marks 14 points wide, which is AgentMark's size.
            AgentMark(state: summary.state)
                .help(summary.help(now: context.date))
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
}
