import AppKit
import GitCore
import SwiftUI

/// The panel on the right of the window, which lists the repository's branches,
/// remotes, tags and stashes (docs/main-window.md). Clicking a ref selects its
/// commit in history.
///
/// It draws its own rows rather than using a `List`, for the same reason as the
/// sidebar: its rows swap their label for commands on hover. So it handles the
/// arrow keys itself.
struct RefsPanel: View {
    let model: RepositoryModel
    @Binding var isShown: Bool
    /// Shows one of the repository's worktrees in the window, by its folder.
    let showWorktree: (String) -> Void
    @AppStorage(RefsPanelSettings.sort) private var sort = RefsModel.Sort.name
    /// The sections that are collapsed, separated by commas. It's one setting
    /// for every repository, like the sizes of the panels.
    @AppStorage("collapsedRefSections") private var collapsedSections = ""
    @FocusState private var isFilterFocused: Bool
    @FocusState private var isListFocused: Bool

    private var refs: RefsModel { model.refs }

    var body: some View {
        @Bindable var refs = refs
        Panel {
            Text("Refs")
                .font(.system(size: 13, weight: .medium))
                .padding(.leading, 4)
        } trailing: {
            Menu {
                sortPicker
            } label: {
                HoverIcon { Image(systemName: "arrow.up.arrow.down") }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort Refs")
            Menu {
                moreCommands
            } label: {
                HoverIcon { Image(systemName: "ellipsis") }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        } content: {
            VStack(spacing: 0) {
                RefFilterField(text: $refs.filter, isFocused: $isFilterFocused) {
                    isListFocused = true
                    step(by: 1)
                }
                content
            }
            .background(Palette.sideColumn)
        }
        .task(id: model.refsChecks) {
            await refs.load()
        }
        .onChange(of: refs.wantsFilterFocus, initial: true) {
            guard refs.wantsFilterFocus else { return }
            refs.wantsFilterFocus = false
            // The field can't take the keyboard until it's in the window, which
            // takes a moment when the command has just shown the panel.
            Task {
                for _ in 0..<20 where !isFilterFocused {
                    isFilterFocused = true
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch refs.content {
        case .loading:
            RefsLoading()
        case .failed(let message):
            RefsNote(message)
                .textSelection(.enabled)
        case .loaded:
            if let details = refs.shown(sort: sort) {
                list(details)
            }
        }
    }

    private func list(_ details: RefDetails) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let isFiltering = !refs.filter.isEmpty
                    if isFiltering, details.isEmpty {
                        Text("No refs match “\(refs.filter)”")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(16)
                            .frame(maxWidth: .infinity)
                    }
                    section(.branches, count: details.branches.count) {
                        ForEach(details.branches, id: \.name) { branch in
                            branchRow(branch, isCurrent: branch.name == details.currentBranch)
                        }
                    }
                    section(.remotes, count: details.remotes.count) {
                        ForEach(details.remotes, id: \.name) { remote in
                            RefRow(
                                systemImage: "cloud",
                                title: remote.name,
                                subtitle: remote.address ?? "Not configured any more"
                            )
                            ForEach(remote.branches, id: \.name) { branch in
                                remoteBranchRow(branch)
                            }
                        }
                    }
                    section(.tags, count: details.tags.count) {
                        ForEach(details.tags, id: \.name) { tag in
                            tagRow(tag)
                        }
                    }
                    section(.stashes, count: details.stashes.count) {
                        ForEach(details.stashes, id: \.position) { stash in
                            RefRow(systemImage: "tray", title: stash.message, subtitle: stash.subtitle(), titleTruncation: .tail)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                step(by: press.key == .downArrow ? 1 : -1)
                return .handled
            }
            .onChange(of: refs.selectionSteps) {
                if let name = refs.selectedRef { scroller.scrollTo(name) }
            }
        }
    }

    /// A section, unless a filter left it with nothing to show.
    @ViewBuilder private func section<Rows: View>(_ section: RefsModel.Section, count: Int, @ViewBuilder rows: () -> Rows) -> some View {
        if refs.filter.isEmpty || count > 0 {
            let isCollapsed = isCollapsed(section)
            // Each section is a stack of its own, so that all but a repository's
            // remotes have rows of one height, and the stack can tell how tall
            // it is without having laid them all out.
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                Section {
                    if !isCollapsed {
                        if count == 0 {
                            Text(section.emptyNote)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .frame(height: 28)
                        } else {
                            rows()
                        }
                    }
                } header: {
                    RefSectionHeader(section: section, count: count, isCollapsed: isCollapsed) {
                        isListFocused = true
                        setCollapsed(!isCollapsed, section)
                    }
                }
            }
        }
    }

    private func branchRow(_ branch: BranchDetails, isCurrent: Bool) -> some View {
        let otherWorktree = isCurrent ? nil : branch.worktree
        return RefRow(
            systemImage: "arrow.triangle.branch",
            imageColor: isCurrent ? .green : .secondary,
            title: branch.shortName,
            subtitle: branch.subtitle(isCurrent: isCurrent),
            isSelected: isSelected(branch.name, branch.tip),
            hasCommands: otherWorktree != nil,
            action: { select(branch.name, branch.tip) }
        ) {
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Checked out")
            } else if let comparison = branch.comparison {
                AheadBehind(ahead: comparison.ahead, behind: comparison.behind)
            }
        } commands: {
            if let otherWorktree {
                Button { showWorktree(otherWorktree) } label: { Image(systemName: "arrow.right.circle") }
                    .buttonStyle(.icon(size: 24))
                    .help("Show Worktree")
            }
        } menu: {
            if let otherWorktree {
                Button("Show Worktree") { showWorktree(otherWorktree) }
                Divider()
            }
            Button("Copy Name") { copy(branch.shortName) }
        }
        .id(branch.name)
    }

    private func remoteBranchRow(_ branch: RemoteBranchDetails) -> some View {
        RefRow(
            systemImage: "arrow.triangle.branch",
            title: branch.shortName,
            isSelected: isSelected(branch.name, branch.tip),
            isIndented: true,
            action: { select(branch.name, branch.tip) }
        ) {
            if let date = branch.date {
                Text(RefDates.short(date))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        } commands: {
        } menu: {
            Button("Copy Name") { copy(Ref.shortName(branch.name)) }
        }
        .id(branch.name)
    }

    private func tagRow(_ tag: TagDetails) -> some View {
        RefRow(
            systemImage: "tag",
            title: tag.shortName,
            subtitle: tag.subject ?? "No commit to show",
            isSelected: tag.commit.map { isSelected(tag.name, $0) } ?? false,
            action: tag.commit.map { commit in { select(tag.name, commit) } }
        ) {
        } commands: {
        } menu: {
            Button("Copy Name") { copy(tag.shortName) }
        }
        .id(tag.name)
    }

    private func isSelected(_ name: String, _ commit: ObjectID) -> Bool {
        refs.selectedRef == name && model.selectedCommit.id == commit
    }

    private func select(_ name: String, _ commit: ObjectID) {
        isListFocused = true
        model.select(ref: name, commit: commit)
    }

    /// Moves the selection through the rows that show, skipping stashes, which
    /// have no commit in history.
    private func step(by step: Int) {
        guard let details = refs.shown(sort: sort) else { return }
        let rows = selectableRows(details)
        let selected = rows.firstIndex { isSelected($0.name, $0.commit) }
        let index = selected.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)
        guard rows.indices.contains(index) else { return }
        refs.step(to: rows[index].name)
        model.select(commit: rows[index].commit)
    }

    private func selectableRows(_ details: RefDetails) -> [(name: String, commit: ObjectID)] {
        var rows: [(name: String, commit: ObjectID)] = []
        if !isCollapsed(.branches) {
            rows += details.branches.map { ($0.name, $0.tip) }
        }
        if !isCollapsed(.remotes) {
            rows += details.remotes.flatMap { $0.branches.map { ($0.name, $0.tip) } }
        }
        if !isCollapsed(.tags) {
            rows += details.tags.compactMap { tag in tag.commit.map { (tag.name, $0) } }
        }
        return rows
    }

    /// Whether a section is showing only its header. A filter opens every
    /// section, because otherwise it could seem to find nothing.
    private func isCollapsed(_ section: RefsModel.Section) -> Bool {
        refs.filter.isEmpty && collapsedSections.split(separator: ",").contains(Substring(section.rawValue))
    }

    private func setCollapsed(_ isCollapsed: Bool, _ section: RefsModel.Section) {
        var sections = Set(collapsedSections.split(separator: ",").map(String.init))
        if isCollapsed { sections.insert(section.rawValue) } else { sections.remove(section.rawValue) }
        collapsedSections = sections.sorted().joined(separator: ",")
    }

    private var sortPicker: some View {
        Picker("Sort By", selection: $sort) {
            ForEach(RefsModel.Sort.allCases, id: \.self) { sort in
                Text(sort.title).tag(sort)
            }
        }
        .pickerStyle(.inline)
    }

    @ViewBuilder private var moreCommands: some View {
        sortPicker
        Divider()
        Button("Filter Refs") { isFilterFocused = true }
            .keyboardShortcut(RepositoryCommands.filterRefsShortcut)
        Button("Collapse All Sections") {
            collapsedSections = RefsModel.Section.allCases.map(\.rawValue).joined(separator: ",")
        }
        Button("Expand All Sections") { collapsedSections = "" }
        Divider()
        Button("Hide Refs") { isShown = false }
            .keyboardShortcut(RepositoryCommands.refsPanelShortcut)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The names of the settings that the panel and the menu bar share.
enum RefsPanelSettings {
    static let sort = "refsSort"
}

extension RefDetails {
    /// Whether every section has nothing to list.
    fileprivate var isEmpty: Bool {
        branches.isEmpty && remotes.isEmpty && tags.isEmpty && stashes.isEmpty
    }
}

/// A spinner that waits a moment, so that reading the lists doesn't flash it.
private struct RefsLoading: View {
    @State private var isTakingLong = false

    var body: some View {
        ZStack {
            if isTakingLong {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            isTakingLong = true
        }
    }
}

/// A sentence in place of the lists.
private struct RefsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the panel shows when the window isn't showing a worktree.
struct RefsPanelPlaceholder: View {
    var body: some View {
        Panel {
            Text("Refs")
                .font(.system(size: 13, weight: .medium))
                .padding(.leading, 4)
        } trailing: {
        } content: {
            RefsNote("Choose a worktree to see its repository's refs.")
                .background(Palette.sideColumn)
        }
    }
}

/// The field that narrows every section at once. The down arrow goes to the
/// list, and Escape clears the field.
private struct RefFilterField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let moveToList: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Filter branches, tags and stashes", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused(isFocused)
                .onKeyPress(.downArrow) {
                    moveToList()
                    return .handled
                }
                .onExitCommand { text = "" }
                .accessibilityLabel("Filter Refs")
            if !text.isEmpty {
                Button("Clear the Filter", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .help("Clear the Filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isFocused.wrappedValue ? Color.primary.opacity(0.35) : Palette.separator)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// A section's title with a triangle after it, and how many items it has.
/// Clicking it collapses or expands the section. It stays in place as the
/// section's rows scroll under it, so it has a background of its own.
private struct RefSectionHeader: View {
    let section: RefsModel.Section
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(section.title)
                .font(.system(size: 12, weight: .semibold))
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
            Spacer(minLength: 8)
            Text(count, format: .number)
                .font(.system(size: 11.5))
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: 28)
        .background(Palette.sideColumn)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(section.title)
        .accessibilityValue("\(count), \(isCollapsed ? "Collapsed" : "Expanded")")
        .accessibilityHint("Shows or hides its rows")
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityAction(.default, toggle)
    }
}

/// A row in the panel. It fills with gray while the pointer is over it, if
/// clicking it does something, and a little darker while it's selected. A label
/// beside its first line gives way to its commands while the pointer is over
/// it, and its second line has the whole width.
private struct RefRow<Trailing: View, Commands: View, MenuItems: View>: View {
    let systemImage: String
    var imageColor = Color.secondary
    let title: String
    var subtitle: String?
    /// Where a title that doesn't fit gives way. A ref's name usually differs
    /// at its end, so that stays, and a sentence reads from its start.
    var titleTruncation = Text.TruncationMode.middle
    var isSelected = false
    var isIndented = false
    var hasCommands = false
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var commands: Commands
    @ViewBuilder var menu: MenuItems
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(imageColor)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(titleTruncation)
                    Spacer(minLength: 0)
                    // As tall as the line, so that a command's button doesn't
                    // move the text.
                    HStack(spacing: 0) {
                        if isHovering && hasCommands {
                            commands
                        } else {
                            trailing
                        }
                    }
                    .frame(height: 16)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.leading, isIndented ? 30 : 8)
        .padding(.trailing, 8)
        .frame(height: subtitle == nil ? 28 : 40)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Palette.selection : isHovering && action != nil ? Palette.hover : .clear)
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .onHover { isHovering = $0 }
        .help(title)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : action == nil ? [] : .isButton)
        .accessibilityAction(.default) { action?() }
        .accessibilityActions { menu }
    }
}

extension RefRow where Trailing == EmptyView, Commands == EmptyView, MenuItems == EmptyView {
    /// A row with nothing but its text, such as a stash's.
    init(systemImage: String, title: String, subtitle: String, titleTruncation: Text.TruncationMode = .middle) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle, titleTruncation: titleTruncation) {
        } commands: {
        } menu: {
        }
    }
}

/// How far a branch is from the one it's compared with, as arrows.
private struct AheadBehind: View {
    let ahead: Int
    let behind: Int

    var body: some View {
        HStack(spacing: 6) {
            if ahead > 0 {
                Text("↑\(ahead)")
                    .foregroundStyle(.green)
            }
            if behind > 0 {
                Text("↓\(behind)")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .accessibilityHidden(true)
    }
}

/// Whether a window shows its refs panel: whether the user wants it, and whether
/// it fits. The panel gives way when the window gets narrow (decision 13), and
/// comes back when there's room for it again.
struct RefsPanelVisibility {
    /// The panel's width until someone drags it wider, from the wireframe.
    static let defaultWidth = 288.0
    static let maximumWidth = 400.0
    /// How wide the middle of the window has to stay. macOS keeps the middle at
    /// least as wide as the sidebar, and clips the columns rather than making
    /// the window wider, so this is as wide as the sidebar can get. The panels
    /// under history need 361 points of it.
    static let minimumMiddleWidth = 400.0

    var isWanted: Binding<Bool>
    var fits: Bool

    var isShowing: Bool { isWanted.wrappedValue && fits }
    var commandTitle: String { isShowing ? "Hide Refs" : "Show Refs" }

    /// It goes by the panel's usual width rather than measuring the panel,
    /// which measures wider than it is while it opens, and it only depends on
    /// what showing the panel doesn't change. Otherwise the panel could show
    /// and hide forever.
    static func fits(window: Double, sidebar: Double) -> Bool {
        window - sidebar - defaultWidth >= minimumMiddleWidth
    }
}

/// Hides or shows the refs panel. It's a plain icon like the button for the
/// sidebar, rather than the glass button macOS puts in the toolbar.
struct RefsPanelToggle: View {
    let visibility: RefsPanelVisibility

    var body: some View {
        Button {
            visibility.isWanted.wrappedValue.toggle()
        } label: {
            Image(systemName: "sidebar.right")
        }
        .buttonStyle(.icon)
        .disabled(!visibility.fits)
        .help(visibility.fits ? visibility.commandTitle : "Make the Window Wider to Show Refs")
        .accessibilityLabel(visibility.commandTitle)
    }
}

extension FocusedValues {
    /// Whether the focused window shows its refs panel, for the View menu.
    @Entry var refsPanelVisibility: RefsPanelVisibility?
}
