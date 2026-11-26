import AppKit
import GitCore
import IconUI
import MenuUI
import SwiftUI

/// What the tabs along the top of the window do, which the window hands them
/// (decision 95).
struct WorktreeTabActions {
    /// Shows the worktree in this folder in the window.
    var show: (String) -> Void
    /// Opens the worktree in this folder in a new window.
    var openInNewWindow: (String) -> Void
    /// Makes a new branch in a new worktree, from the worktree in the first
    /// folder, with the name given second, and shows it.
    ///
    /// - Returns: What git said if it refused, which the popover shows.
    var createWorktree: (_ from: String, _ name: String) async -> String?
    /// Asks where a worktree whose folder is missing is now.
    var locate: (Worktree) -> Void
    var delete: (Worktree) -> Void
    /// Asks where the repository is now, when it can't be found.
    var locateRepository: () -> Void
    var removeRepository: () -> Void
}

/// The shown repository's worktrees as tabs, along the top of the window
/// (decision 95). The repository's own folder, its main worktree, comes first
/// under the repository's name, and can't go away. A thin line follows it, then
/// a tab for each linked worktree in the order git lists them, which is the
/// order Command-1 to Command-9 go in, then a button for a new worktree.
///
/// It works the tabs out in its own body, which reads what agents are doing, so
/// that a mark changing redraws the tabs rather than the whole window. While an
/// agent works or waits in one of the worktrees, it also redraws as that agent
/// reaches another minute, so that the tooltips say for how long.
struct WorktreeTabStrip: View {
    let repository: ListedRepository
    /// The folder of the worktree the window shows.
    let shown: String
    /// The model of the worktree on screen, once its repository is open.
    let model: RepositoryModel?
    let monitor: AgentMonitor
    let list: RepositoryList
    let actions: WorktreeTabActions
    /// The worktree whose popover for a new worktree is open in this window,
    /// which hangs from its tab, or for the main worktree from the button
    /// after the tabs.
    @Binding var newWorktreeFrom: WorktreeSelection?
    /// Whether the tabs show what agents are doing. It follows the sidebar's
    /// marks, so that turning agents off hides them here too.
    var marks = AgentMarksSetting()

    var body: some View {
        let tabs = facts
        TimelineView(WholeMinutes(of: tabs.map(\.agent))) { context in
            HStack(spacing: 4) {
                ForEach(Array(tabs.enumerated()), id: \.element.worktree.path) { index, facts in
                    tab(facts, index: index, now: context.date)
                    // The repository's own folder stands apart from the
                    // worktrees made from it.
                    if facts.worktree.isMain, tabs.count > 1 {
                        Rectangle()
                            .fill(Palette.separator)
                            .frame(width: 1, height: 16)
                            .padding(.horizontal, 2)
                            .accessibilityHidden(true)
                    }
                }
                if let main = repository.worktrees.first, main.isMain, !main.isBare {
                    NewWorktreeTabButton(
                        start: NewWorktreePopover.start(of: main),
                        isPresented: isMakingWorktree(from: selection(of: main))
                    ) { name in
                        await actions.createWorktree(main.path, name)
                    }
                }
            }
        }
    }

    /// What each tab says, in the order the tabs go. A bare repository's entry
    /// has no files to show, so it has no tab, as it has no row in the menu bar's
    /// Show Worktree.
    var facts: [WorktreeFacts] {
        WorktreeTabs.tabs(WorktreeMenu.facts(of: repository, shown: shown, model: model, agents: marks.monitor(monitor), in: list))
    }

    @ViewBuilder private func tab(_ facts: WorktreeFacts, index: Int, now: Date) -> some View {
        let worktree = facts.worktree
        let selection = self.selection(of: worktree)
        let menu = self.menu(for: worktree, selection: selection)
        let tab = WorktreeTab(
            facts: facts,
            title: worktree.isMain ? repository.name : nil,
            isSelected: worktree.path == shown,
            help: WorktreeTabs.help(for: facts, repositoryName: worktree.isMain ? repository.name : nil, index: index, now: now),
            menu: menu
        ) {
            actions.show(worktree.path)
        }
        if worktree.isMain {
            // The main worktree's popover hangs from the button for a new
            // worktree, which is where it's asked for most.
            tab
        } else {
            tab.popover(isPresented: isMakingWorktree(from: selection), arrowEdge: .bottom) {
                NewWorktreePopover(start: NewWorktreePopover.start(of: worktree)) { name in
                    await actions.createWorktree(worktree.path, name)
                }
            }
        }
    }

    private func selection(of worktree: Worktree) -> WorktreeSelection {
        WorktreeSelection(repository: repository.path, worktree: worktree.path)
    }

    private func isMakingWorktree(from selection: WorktreeSelection) -> Binding<Bool> {
        Binding {
            newWorktreeFrom == selection
        } set: { isPresented in
            if isPresented {
                newWorktreeFrom = selection
            } else if newWorktreeFrom == selection {
                newWorktreeFrom = nil
            }
        }
    }

    /// The menu of the worktree's row in the sidebar, which the tab's … button
    /// and a right-click open: the repository's for its own tab, and the
    /// worktree's for the others.
    private func menu(for worktree: Worktree, selection: WorktreeSelection) -> [RefMenu.Entry] {
        if worktree.isMain {
            return SidebarMenus.entries(
                forRepository: repository.session == nil ? nil : worktree,
                cantOpen: false,
                actions: SidebarMenus.RepositoryActions(
                    openInNewWindow: { actions.openInNewWindow(worktree.path) },
                    newWorktree: { newWorktreeFrom = selection },
                    locate: actions.locateRepository,
                    remove: actions.removeRepository,
                    reveal: reveal,
                    openInTerminal: openInTerminal
                )
            )
        }
        return SidebarMenus.entries(
            forWorktree: worktree,
            isDeleting: repository.deletingWorktrees.contains(worktree.path),
            actions: SidebarMenus.WorktreeActions(
                openInNewWindow: { actions.openInNewWindow(worktree.path) },
                newWorktree: { newWorktreeFrom = selection },
                locate: { actions.locate(worktree) },
                delete: { actions.delete(worktree) },
                reveal: reveal,
                openInTerminal: openInTerminal
            )
        )
    }
}

/// What a tab shows, worked out from what's known about its worktree.
enum WorktreeTabs {
    /// What sits before a tab's name.
    enum Mark: Equatable {
        /// What agents are doing there, as the sidebar's mark shows it.
        case agent(AgentSummary.State)
        /// Files with conflicts, or a merge, rebase or revert that stopped on them.
        case conflicts
        case folderMissing
        case locked
        /// The repository's own folder, with nothing else to say.
        case repository
        /// A linked worktree, with nothing else to say.
        case worktree
    }

    /// The one number after a tab's name.
    enum Badge: Equatable {
        /// Uncommitted files, some with conflicts, in red.
        case conflicts(Int)
        /// git couldn't list the uncommitted files, which an orange triangle says.
        case cantList
        /// Uncommitted files, in orange as in the sidebar.
        case uncommitted(Int)
        /// Commits to pull, in gray, because clicking the tab doesn't pull.
        case behind(Int)
        /// Commits to push, in gray, because clicking the tab doesn't push. For a
        /// branch that has never had an upstream, it's the commits that the
        /// main branch doesn't have, which haven't gone anywhere yet.
        case ahead(Int)
    }

    /// The worktrees that have tabs, in the order git lists them, which leaves
    /// out a bare repository's entry.
    static func tabs(_ facts: [WorktreeFacts]) -> [WorktreeFacts] {
        facts.filter { !$0.worktree.isBare }
    }

    /// A branch's name in two parts, as in `agent/` and `fix-login`, so that the
    /// tab can dim the folder and keep the part that tells branches apart in
    /// full color. A name without a slash, and a detached `HEAD`, have no folder.
    static func nameParts(of worktree: Worktree) -> (folder: String, name: String) {
        let title = worktree.title
        guard worktree.branch != nil,
              let slash = title.lastIndex(of: "/"),
              title.index(after: slash) < title.endIndex else { return ("", title) }
        return (String(title[...slash]), String(title[title.index(after: slash)...]))
    }

    /// An agent waiting for you comes first, as on a sidebar row's second line,
    /// then conflicts, then an agent at work or one that finished, then what
    /// stops the worktree being used. Otherwise it's the repository's icon on
    /// its own tab and the worktree icon on the others, as in the sidebar's
    /// menus.
    static func mark(for facts: WorktreeFacts) -> Mark {
        if let agent = facts.agent, case .waiting = agent.state { return .agent(agent.state) }
        if facts.hasConflicts || facts.unfinished?.hasConflicts == true { return .conflicts }
        if let agent = facts.agent { return .agent(agent.state) }
        if facts.worktree.isPrunable { return .folderMissing }
        if facts.worktree.isLocked { return .locked }
        return facts.worktree.isMain ? .repository : .worktree
    }

    /// The most pressing of what a worktree has waiting: conflicts, then files
    /// git couldn't list, then uncommitted files, then commits to pull, then
    /// commits to push. A branch that has never had an upstream counts what it
    /// would push against the main branch, as the refs panel does, so that a
    /// worktree whose commits haven't gone anywhere doesn't look like one with
    /// nothing waiting. Only one shows, so that tabs stay short. The rest is in
    /// the tooltip.
    static func badge(for facts: WorktreeFacts) -> Badge? {
        if facts.hasConflicts, facts.uncommittedFiles > 0 { return .conflicts(facts.uncommittedFiles) }
        if facts.statusFailure != nil { return .cantList }
        if facts.uncommittedFiles > 0 { return .uncommitted(facts.uncommittedFiles) }
        if let upstream = facts.upstream {
            guard !upstream.isGone else { return nil }
            if upstream.behind > 0 { return .behind(upstream.behind) }
            if upstream.ahead > 0 { return .ahead(upstream.ahead) }
        } else if let main = facts.aheadOfMain, main.ahead > 0 {
            return .ahead(main.ahead)
        }
        return nil
    }

    /// The tab's tooltip: the branch's whole name and the shortcut that shows
    /// it, then everything the menu bar's worktree rows say about it, which
    /// ends with its folder.
    ///
    /// - Parameters:
    ///   - repositoryName: The repository's name, for its own tab.
    ///   - index: Where the tab is among the tabs, for its shortcut.
    ///   - now: The time to say how long agents have been at it from.
    static func help(for facts: WorktreeFacts, repositoryName: String?, index: Int, now: Date = .now) -> String {
        var title = repositoryName.map { "\($0), on \(facts.worktree.title)" } ?? facts.worktree.title
        if index < 9 { title += "  ⌘\(index + 1)" }
        let details = WorktreeMenu.details(for: facts, now: now).map(\.text).joined(separator: " · ")
        return [title, details, StatusFailureNote.worktree(facts.statusFailure)?.help]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// One tab. The tab the window shows is white in the light theme, has an edge
/// and casts a soft shadow, as in the Claude app, and the others fill with
/// gray under the pointer. A tab keeps a place at its end for its number,
/// which the … button covers on hover, the way a sidebar row's menu button
/// covers its mark (decision 58), so that nothing moves as the pointer passes.
/// The button opens the menu of the worktree's row in the sidebar, which a
/// right-click on the tab opens too.
///
/// A tab is shown as soon as the mouse button goes down on it, as a row in a
/// list is, rather than when it comes back up, and it has no look of its own
/// while it's held.
private struct WorktreeTab: View {
    let facts: WorktreeFacts
    /// What the tab says in place of the branch, as the repository's own tab
    /// says the repository's name.
    let title: String?
    let isSelected: Bool
    let help: String
    let menu: [RefMenu.Entry]
    let select: () -> Void
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private static let height: CGFloat = 32
    private static let menuButtonSize: CGFloat = 24
    /// The edge of the tab the window shows, a touch stronger than the line
    /// under the title row. It's light, as in the Claude app, and the tab's
    /// shadow does the rest of setting it apart from the row.
    private static let edge = Palette.gray(light: 0.87, dark: 0.30)
    /// The fill of the tab the window shows: white in the light theme, as in
    /// the Claude app, and in the dark a gray a step lighter than the title
    /// row, as light as a selected row's fill makes it. It's opaque, so that
    /// it casts its shadow.
    private static let fill = Palette.gray(light: 1.0, dark: 0.23)

    private var worktree: Worktree { facts.worktree }

    /// A worktree whose folder is missing, or that's being deleted, can't be
    /// shown, as in the sidebar.
    private var canSelect: Bool {
        !worktree.isPrunable && !facts.isDeleting
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        let showsMenu = isHovering && !facts.isDeleting
        let badge = WorktreeTabs.badge(for: facts)
        // A button, so that a press on it in the title row isn't taken for
        // the start of moving the window, as one on a view with a gesture is.
        Button {
            if canSelect { select() }
        } label: {
            HStack(spacing: 6) {
                TabMark(mark: WorktreeTabs.mark(for: facts))
                label
                    .opacity(worktree.isPrunable ? 0.6 : 1)
                ZStack(alignment: .trailing) {
                    Color.clear
                        .frame(width: Self.menuButtonSize, height: 1)
                    if let badge {
                        TabBadge(badge: badge)
                            .opacity(showsMenu ? 0 : 1)
                    }
                }
                .fixedSize()
            }
            .padding(.leading, 9)
            .padding(.trailing, 4)
            .frame(height: Self.height)
            .background {
                if isSelected {
                    // The shadow spreads evenly around the tab, as in the
                    // Claude app, rather than falling below it.
                    shape.fill(Self.fill)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.12), radius: 2)
                } else if isHovering && canSelect {
                    shape.fill(Palette.hover)
                }
            }
            .overlay {
                if isSelected {
                    shape.strokeBorder(Self.edge)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(SelectsOnPress { if canSelect { select() } })
        .overlay(alignment: .trailing) {
            if showsMenu {
                TabMenuButton(entries: menu, size: Self.menuButtonSize)
                    .padding(.trailing, 4)
            }
        }
        .overlay { RefMenuArea(entries: menu) }
        .opacity(facts.isDeleting ? 0.5 : 1)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.map { "Repository \($0)" } ?? worktree.title)
        .accessibilityValue(help)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) {
            if canSelect { select() }
        }
        .accessibilityActions { refMenuActions(menu) }
    }

    /// The branch's folder in gray, then the rest of its name, which fades out
    /// at its end when the tab is short of room, as names in the sidebar do
    /// (decision 51).
    private var label: some View {
        let parts = title.map { (folder: "", name: $0) } ?? WorktreeTabs.nameParts(of: worktree)
        return FadingText(Text("\(Text(parts.folder).foregroundStyle(.secondary))\(parts.name)"))
            .font(.system(size: 13))
            // A few letters stay, so that a crowded strip still tells tabs apart.
            .frame(minWidth: Self.shortestLabelWidth(parts.folder + parts.name))
    }

    /// How narrow the name can get: all of a short one, and otherwise about
    /// four letters.
    private static func shortestLabelWidth(_ name: String) -> CGFloat {
        let width = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width.rounded(.up)
        return min(width, 36)
    }
}

/// Runs as the mouse button goes down on the button, where a button's action
/// waits for it to come back up, and draws the label as it is, with no look of
/// its own while it's held. The action still runs as the button comes up, and
/// for the keyboard.
private struct SelectsOnPress: ButtonStyle {
    let pressed: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { pressed() }
            }
    }
}

/// The mark before a tab's name, in an 18-point box.
private struct TabMark: View {
    let mark: WorktreeTabs.Mark

    var body: some View {
        Group {
            switch mark {
            case .agent(let state):
                AgentMark(state: state, size: 16)
            case .conflicts:
                Icon.warning.image
                    .foregroundStyle(Palette.red)
            case .folderMissing:
                Icon.folderX.image
                    .foregroundStyle(.secondary)
            case .locked:
                Icon.lock.image
                    .foregroundStyle(.secondary)
            case .repository:
                Icon.repository.image
                    .foregroundStyle(.secondary)
            case .worktree:
                Icon.worktree.image
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 15))
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

/// The number at the end of a tab.
private struct TabBadge: View {
    let badge: WorktreeTabs.Badge

    var body: some View {
        HStack(spacing: 2) {
            switch badge {
            case .conflicts(let count), .uncommitted(let count):
                Text(count, format: .number)
            case .cantList:
                Icon.warning.image
            case .behind(let count):
                Text("↓" + count.formatted())
            case .ahead(let count):
                Text("↑" + count.formatted())
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1)
        .padding(.trailing, 4)
        .accessibilityHidden(true)
    }

    private var color: AnyShapeStyle {
        switch badge {
        case .conflicts: AnyShapeStyle(Palette.red)
        case .cantList, .uncommitted: AnyShapeStyle(Color.orange)
        case .behind, .ahead: AnyShapeStyle(.secondary)
        }
    }
}

/// The button that opens a tab's menu, which shows while the pointer is over
/// the tab.
private struct TabMenuButton: View {
    let entries: [RefMenu.Entry]
    let size: CGFloat

    var body: some View {
        HoverIcon(size: size) { Icon.ellipsis.image }
            .overlay { RefMenuArea(entries: entries, opensOnClick: true) }
            .help("More")
            // The tab offers the same commands as actions of its own.
            .accessibilityHidden(true)
    }
}

/// Makes a new worktree from the repository's own folder, in a popover that
/// hangs from the button, after the last tab.
private struct NewWorktreeTabButton: View {
    /// What the new branch starts from, as in `main`.
    let start: String?
    @Binding var isPresented: Bool
    let create: (String) async -> String?

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Icon.plus.image
        }
        .buttonStyle(.icon(isOn: isPresented))
        .opensOnPress($isPresented)
        .help(NewWorktreePopover.title(startingFrom: start))
        .accessibilityLabel(NewWorktreePopover.title(startingFrom: start))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            NewWorktreePopover(start: start, create: create)
        }
    }
}
