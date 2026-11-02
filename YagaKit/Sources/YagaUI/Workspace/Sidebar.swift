import AppKit
import GitCore
import SwiftUI

/// The window's sidebar: actions such as opening a repository, then every
/// repository with its worktrees under it (docs/main-window.md).
///
/// It draws its own rows rather than using a `List`, because its rows fill
/// with gray on hover and when selected, and swap a label for commands on
/// hover, which a sidebar list can't do. So it handles the arrow keys
/// itself.
struct Sidebar: View {
    let list: RepositoryList
    @Binding var selection: WorktreeSelection?
    let open: () -> Void
    let locate: (ListedRepository) -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ActionRow(title: "Open Repository…", systemImage: "plus", shortcut: RepositoryCommands.openShortcut, action: open)
                        .disabled(!list.isConnected)
                    Text("Repositories")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(EdgeInsets(top: 14, leading: 8, bottom: 4, trailing: 8))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(list.repositories) { repository in
                        RepositoryRow(repository: repository, list: list) {
                            isFocused = true
                            list.setExpanded(!repository.isExpanded, repository)
                        } locate: {
                            locate(repository)
                        }
                        .padding(.top, repository === list.repositories.first ? 0 : 6)
                        if repository.isExpanded {
                            ForEach(repository.worktrees, id: \.path) { worktree in
                                let row = WorktreeSelection(repository: repository.path, worktree: worktree.path)
                                WorktreeRow(worktree: worktree, uncommittedFiles: repository.uncommittedFiles[worktree.path] ?? 0, isSelected: selection == row) {
                                    select(row)
                                } openInNewWindow: {
                                    openWindow(value: WorkspaceWindow(selection: row))
                                }
                                .id(row)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                handle(press.key, scroller)
            }
        }
    }

    private func select(_ row: WorktreeSelection) {
        isFocused = true
        selection = row
    }

    /// Every worktree row in the order the sidebar lists them, and whether
    /// it's showing and can be selected.
    private var rows: [(selection: WorktreeSelection, isSelectable: Bool)] {
        list.repositories.flatMap { repository in
            repository.worktrees.map { worktree in
                (WorktreeSelection(repository: repository.path, worktree: worktree.path), repository.isExpanded && !worktree.isPrunable)
            }
        }
    }

    /// The up and down arrows move between worktrees, skipping the ones in
    /// collapsed repositories. The right and left arrows show and hide the
    /// worktrees of the selected one's repository.
    private func handle(_ key: KeyEquivalent, _ scroller: ScrollViewProxy) -> KeyPress.Result {
        switch key {
        case .upArrow, .downArrow:
            let step = key == .downArrow ? 1 : -1
            let rows = rows
            var index = rows.firstIndex { $0.selection == selection } ?? (step > 0 ? -1 : rows.count)
            repeat {
                index += step
            } while rows.indices.contains(index) && !rows[index].isSelectable
            guard rows.indices.contains(index) else { return .handled }
            select(rows[index].selection)
            scroller.scrollTo(rows[index].selection)
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

/// A row in the sidebar. It fills with gray while the pointer is over it,
/// and a little darker while it's selected. Its top right corner shows a
/// label, which gives way to the row's commands while the pointer is over
/// it. The commands are 24-point buttons 4 points from the row's top and
/// right edges, so they're centered in a one-line row and beside the first
/// line of a two-line row.
private struct SidebarRow<Content: View, Trailing: View, Commands: View>: View {
    var isSelected = false
    var isEnabled = true
    let height: CGFloat
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
        .frame(height: height)
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

/// The heights of sidebar rows, the same as in the Claude app's sidebar,
/// which the wireframe follows.
private enum SidebarRowHeight {
    /// A row with one line of text.
    static let oneLine: CGFloat = 32
    /// A row with a second, smaller line under the first.
    static let twoLines: CGFloat = 54
}

/// An action at the top of the sidebar, such as opening a repository. Its
/// keyboard shortcut shows on hover.
private struct ActionRow: View {
    let title: String
    let systemImage: String
    let shortcut: KeyboardShortcut
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        SidebarRow(isEnabled: isEnabled, height: SidebarRowHeight.oneLine, action: action) {
            HStack(spacing: 11.5) {
                // A light symbol at this size is 13 points across, as big
                // as the label's capitals are tall, with a thin stroke.
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .light))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
            }
        } trailing: {
            EmptyView()
        } commands: {
            Text(shortcut.symbols)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.trailing, 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }
}

/// A repository's name, with a triangle after it. Clicking it shows or hides
/// the repository's worktrees.
private struct RepositoryRow: View {
    let repository: ListedRepository
    let list: RepositoryList
    let toggle: () -> Void
    let locate: () -> Void

    var body: some View {
        SidebarRow(height: SidebarRowHeight.twoLines, action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(repository.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: repository.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(location)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .opacity(problem == nil ? 1 : 0.6)
        } trailing: {
            if let problem {
                Text(problem)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 7)
            } else {
                HStack(spacing: 8) {
                    if linkedWorktrees > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "square.on.square")
                            Text(linkedWorktrees, format: .number)
                        }
                        .foregroundStyle(.secondary)
                    }
                    if !repository.isExpanded, uncommittedFiles > 0 {
                        Text(uncommittedFiles, format: .number)
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 13))
                .padding(.trailing, 7)
            }
        } commands: {
            if let main {
                Button { reveal(main.path) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                Button { openInTerminal(main.path) } label: { Image(systemName: "apple.terminal") }
                    .help("Open in Terminal")
            }
            Menu {
                menuItems
            } label: {
                HoverIcon(size: 24) { Image(systemName: "ellipsis") }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .buttonStyle(.icon(size: 24))
        .help(repository.path)
        .contextMenu { menuItems }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(repository.name)
        .accessibilityValue(
            [location, linkedWorktreesDescription, uncommittedFilesDescription(uncommittedFiles), repository.isExpanded ? "Expanded" : "Collapsed", problem]
                .compactMap(\.self)
                .joined(separator: ", ")
        )
        .accessibilityHint("Shows or hides its worktrees")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, toggle)
        .accessibilityActions { menuItems }
    }

    /// The folder the repository is in, which tells apart repositories with
    /// the same name. It comes from the git directory, like the name, so it
    /// shows where a missing repository was.
    private var location: String {
        var folder = repository.path as NSString
        if folder.lastPathComponent == ".git" { folder = folder.deletingLastPathComponent as NSString }
        return (folder.deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }

    /// How many worktrees the repository has besides the main one.
    private var linkedWorktrees: Int {
        repository.worktrees.count { !$0.isMain }
    }

    /// How many files have uncommitted changes in all of its worktrees.
    private var uncommittedFiles: Int {
        repository.uncommittedFiles.values.reduce(0, +)
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

    @ViewBuilder private var menuItems: some View {
        if let main {
            Button("Show in Finder") { reveal(main.path) }
            Button("Open in Terminal") { openInTerminal(main.path) }
        } else if problem != nil {
            Button("Locate…", action: locate)
        }
        Divider()
        Button("Remove from Sidebar") { list.remove(repository) }
    }
}

/// A worktree's branch, and its folder under it.
private struct WorktreeRow: View {
    let worktree: Worktree
    let uncommittedFiles: Int
    let isSelected: Bool
    let select: () -> Void
    let openInNewWindow: () -> Void

    var body: some View {
        SidebarRow(isSelected: isSelected, isEnabled: !worktree.isPrunable, height: SidebarRowHeight.twoLines, action: select) {
            lines
        } trailing: {
            if uncommittedFiles > 0 {
                Text(uncommittedFiles, format: .number)
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .padding(.trailing, 7)
            }
        } commands: {
            commands
        }
        .buttonStyle(.icon(size: 24))
        .help(worktree.path)
        .contextMenu { menuItems }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(worktree.title)
        .accessibilityValue([subtitle, uncommittedFilesDescription(uncommittedFiles)].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityActions { menuItems }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(worktree.title)
                .font(.system(size: 14))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, 14)
    }

    @ViewBuilder private var commands: some View {
        Button(action: openInNewWindow) { Image(systemName: "macwindow.badge.plus") }
            .help("Open in New Window")
        Button { openInTerminal(worktree.path) } label: { Image(systemName: "apple.terminal") }
            .help("Open in Terminal")
    }

    private var subtitle: String {
        worktree.isPrunable ? "Its folder is missing" : (worktree.path as NSString).lastPathComponent
    }

    @ViewBuilder private var menuItems: some View {
        Button("Open in New Window", action: openInNewWindow)
        Divider()
        Button("Show in Finder") { reveal(worktree.path) }
        Button("Open in Terminal") { openInTerminal(worktree.path) }
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
            Image(systemName: "sidebar.left")
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
}

private func uncommittedFilesDescription(_ count: Int) -> String? {
    switch count {
    case 0: nil
    case 1: "1 uncommitted file"
    default: "\(count) uncommitted files"
    }
}

private func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
}

private func openInTerminal(_ path: String) {
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
