import AppKit
import GitCore
import IconUI
import MenuUI
import SwiftUI

/// The panel on the right of the window, which lists the repository's branches,
/// remotes, tags and stashes (docs/main-window.md). Clicking a ref selects its
/// commit in history, and double-clicking a branch checks it out, as double-clicking
/// its badge there does.
///
/// It draws its own rows rather than using a `List`, for the same reason as the
/// sidebar: its rows swap their label for commands on hover. So it handles the
/// arrow keys itself.
struct RefsPanel: View {
    let model: RepositoryModel
    /// How wide the panel is, which its row in the toolbar has to match.
    let width: Double
    @Binding var isShown: Bool
    /// Shows one of the repository's worktrees in the window, by its folder,
    /// with a commit selected in it.
    let showWorktree: (String, ObjectID?) -> Void
    @AppStorage(RefsPanelSettings.sort) private var sort = RefsModel.Sort.name
    /// The sections that are collapsed, separated by commas. It's one setting
    /// for every repository, like the sizes of the panels.
    @AppStorage("collapsedRefSections") private var collapsedSections = ""
    /// The folders of branches that are closed, by what the full names in them
    /// start with, as in `refs/heads/tm/`, one to a line, since a branch's name
    /// can have a comma but not a line break. Like the sections, it's one
    /// setting for every repository, so a prefix someone uses everywhere stays
    /// open or closed everywhere.
    @AppStorage("collapsedRefFolders") private var collapsedFolders = ""
    @FocusState private var isListFocused: Bool

    private var refs: RefsModel { model.refs }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                // The panel goes up to the top of the window, and this is what it
                // has there. A view's items come after those of the views around
                // it, so this one follows the button that hides the panel, and it's
                // as wide as the panel to keep that button at the panel's edge.
                ToolbarItem {
                    commands
                        .frame(width: RefsPanelVisibility.toolbarItemWidth(panel: width), alignment: .trailing)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .task(id: model.refsChecks) {
                await refs.load()
            }
    }

    /// The panel's commands. The field takes all the room that's left beside
    /// them while it's open.
    private var commands: some View {
        @Bindable var refs = refs
        return HStack(spacing: 4) {
            if refs.isFilterShown {
                PanelSearchField(
                    prompt: "Filter",
                    label: "Filter Refs",
                    text: $refs.filter,
                    wantsFocus: $refs.wantsFilterFocus,
                    moveDown: {
                        isListFocused = true
                        step(by: 1)
                    },
                    close: closeFilter
                )
            }
            Button(refs.isFilterShown ? "Close the Filter" : "Filter Refs", icon: .search) {
                if refs.isFilterShown { closeFilter() } else { refs.showFilter() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.icon(isOn: refs.isFilterShown))
            .help(refs.isFilterShown ? "Close the Filter" : "Filter Refs (\(RepositoryCommands.filterRefsShortcut.symbols))")
            Menu {
                sortPicker
            } label: {
                HoverIcon { Icon.sort.image }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort Refs")
            .accessibilityLabel("Sort Refs")
            Menu {
                moreCommands
            } label: {
                HoverIcon { Icon.ellipsis.image }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
    }

    private func closeFilter() {
        refs.closeFilter()
        isListFocused = true
    }

    @ViewBuilder private var content: some View {
        switch refs.content {
        case .loading:
            RefsLoading()
        case .failed(let message):
            RefsNote(message)
                .textSelection(.enabled)
        case .loaded:
            if let details = refs.shown(sort: sort), let rows = refs.branchRows(sort: sort, collapsed: closedFolders) {
                list(details, rows)
            }
        }
    }

    private func list(_ details: RefDetails, _ rows: BranchRows) -> some View {
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
                        ForEach(rows.local) { row in
                            switch row.content {
                            case .folder(let ref, let name, let count, let isCollapsed):
                                folderRow(ref: ref, name: name, count: count, isCollapsed: isCollapsed, depth: row.depth)
                            case .branch(let branch, let title):
                                branchRow(branch, title: title, depth: row.depth, isCurrent: branch.name == details.currentBranch)
                            }
                        }
                    }
                    section(.remotes, count: details.remotes.count) {
                        ForEach(details.remotes, id: \.name) { remote in
                            RefRemoteRow(name: remote.name, detail: remote.address ?? "Not configured any more")
                            ForEach(rows.remotes[remote.name] ?? []) { row in
                                switch row.content {
                                case .folder(let ref, let name, let count, let isCollapsed):
                                    folderRow(ref: ref, name: name, count: count, isCollapsed: isCollapsed, depth: row.depth, isOnRemote: true)
                                case .branch(let branch, let title):
                                    remoteBranchRow(branch, title: title, depth: row.depth)
                                }
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
                            stashRow(stash)
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
            // Each section is a stack of its own, so that remotes and tags,
            // the sections that can have thousands of rows, have rows of one
            // height, and the stack can tell how tall it is without having laid
            // them all out. A folder's row is shorter than a local branch's,
            // but there are seldom many of either.
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                Section {
                    if !isCollapsed {
                        rows()
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

    /// A folder of branches, which opens and closes.
    private func folderRow(ref: String, name: String, count: Int, isCollapsed: Bool, depth: Int, isOnRemote: Bool = false) -> some View {
        RefFolderRow(name: name, path: Ref.shortName(ref), count: count, isCollapsed: isCollapsed, indent: RefIndent.of(depth, isOnRemote: isOnRemote)) {
            isListFocused = true
            setCollapsed(!isCollapsed, folder: ref)
        }
        .id(ref)
    }

    /// - Parameter title: What's left of the branch's name after the folders
    ///   it's in.
    private func branchRow(_ branch: BranchDetails, title: String, depth: Int, isCurrent: Bool) -> some View {
        let otherWorktree = isCurrent ? nil : branch.worktree
        let reviewBase = model.reviewBase(for: branch.name)?.title
        return RefRow(
            icon: .branch,
            imageColor: isCurrent ? Palette.current : .secondary,
            title: title,
            subtitle: branch.subtitle(isCurrent: isCurrent),
            menu: branchMenu(branch, isCurrent: isCurrent, otherWorktree: otherWorktree, reviewBase: reviewBase),
            isSelected: isSelected(branch.name, branch.tip) || model.reviewedBranch == branch.name,
            indent: RefIndent.of(depth),
            hasCommands: otherWorktree != nil || reviewBase != nil,
            action: { select(branch.name, branch.tip) },
            // There's nothing to do for the current branch, as for its badge.
            doubleAction: isCurrent ? nil : { checkOut(branch.name) }
        ) {
            if isCurrent {
                Icon.check.image
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Checked out")
            } else if let comparison = branch.comparison {
                AheadBehind(ahead: comparison.ahead, behind: comparison.behind)
            }
        } commands: {
            if let reviewBase {
                Button { review(branch.name) } label: { Icon.compare.image }
                    .buttonStyle(.icon(size: 24))
                    .help(isCurrent
                        ? "Review Against \(reviewBase) (\(RepositoryCommands.reviewShortcut.symbols))"
                        : "Review Against \(reviewBase)")
                    .accessibilityLabel("Review Against \(reviewBase)")
            }
            if let otherWorktree {
                Button { showWorktree(otherWorktree, branch.tip) } label: { Icon.worktree.image }
                    .buttonStyle(.icon(size: 24))
                    .help("Show Worktree")
                    .accessibilityLabel("Show Worktree")
            }
        }
        .id(branch.name)
    }

    private func review(_ name: String) {
        isListFocused = true
        model.review(branch: name)
    }

    private func branchMenu(_ branch: BranchDetails, isCurrent: Bool, otherWorktree: String?, reviewBase: String?) -> [RefMenu.Entry] {
        var entries: [RefMenu.Entry] = [.header(branch.shortName)]
        if let reviewBase {
            entries.append(.command("Review Against \(reviewBase)") { review(branch.name) })
        }
        if let otherWorktree {
            entries.append(.command("Show Worktree") { showWorktree(otherWorktree, branch.tip) })
        }
        if reviewBase != nil || otherWorktree != nil {
            entries.append(.divider)
        }
        entries += [
            .command("Copy Name") { copy(branch.shortName) },
            .divider,
            // git won't delete a branch that a worktree has checked out.
            .command(
                "Delete Branch",
                isDestructive: true,
                isEnabled: !isCurrent && branch.worktree == nil && !model.branch.isBusy
            ) {
                model.branch.askToDelete(ref: branch.name)
            },
        ]
        return entries
    }

    private func remoteBranchRow(_ branch: RemoteBranchDetails, title: String, depth: Int) -> some View {
        RefRow(
            icon: .branch,
            title: title,
            menu: [
                // Its full name, because the row's title leaves out the remote.
                .header(Ref.shortName(branch.name)),
                .command("Copy Name") { copy(Ref.shortName(branch.name)) },
                .divider,
                .command("Delete from Remote…", isDestructive: true, isEnabled: !model.branch.isBusy) {
                    model.branch.askToDelete(ref: branch.name)
                },
            ],
            isSelected: isSelected(branch.name, branch.tip),
            indent: RefIndent.of(depth, isOnRemote: true),
            action: { select(branch.name, branch.tip) },
            doubleAction: { checkOut(branch.name) }
        ) {
            if let date = branch.date {
                Text(RefDates.short(date))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        } commands: {
        }
        .id(branch.name)
    }

    private func tagRow(_ tag: TagDetails) -> some View {
        RefRow(
            icon: .tag,
            title: tag.shortName,
            subtitle: tag.subject ?? "No commit to show",
            menu: [
                .header(tag.shortName),
                .command("Copy Name") { copy(tag.shortName) },
            ],
            isSelected: tag.commit.map { isSelected(tag.name, $0) } ?? false,
            action: tag.commit.map { commit in { select(tag.name, commit) } }
        ) {
        } commands: {
        }
        .id(tag.name)
    }

    /// A stash, which shows what it holds in the panels (decision 55).
    private func stashRow(_ stash: StashDetails) -> some View {
        RefRow(
            icon: .stash,
            title: stash.message,
            subtitle: stash.subtitle(),
            isSelected: model.selectedCommit.stash?.commit == stash.commit,
            action: {
                isListFocused = true
                model.select(stash: stash)
            }
        ) {
        } commands: {
        }
        .id(stash.name)
    }

    private func isSelected(_ name: String, _ commit: ObjectID) -> Bool {
        refs.selectedRef == name && model.selectedCommit.id == commit
    }

    private func select(_ name: String, _ commit: ObjectID) {
        isListFocused = true
        model.select(ref: name, commit: commit)
    }

    private func checkOut(_ name: String) {
        model.checkOut(ref: name, showWorktree: showWorktree)
    }

    /// Moves the selection through the rows that show, skipping folders,
    /// remotes and stashes, which have no commit in history.
    private func step(by step: Int) {
        guard let details = refs.shown(sort: sort), let branchRows = refs.branchRows(sort: sort, collapsed: closedFolders) else { return }
        let rows = selectableRows(details, branchRows)
        let selected = rows.firstIndex { isSelected($0.name, $0.commit) }
        let index = selected.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)
        guard rows.indices.contains(index) else { return }
        refs.step(to: rows[index].name)
        model.select(commit: rows[index].commit)
    }

    /// The rows that have a commit to select, which leaves out a closed
    /// folder's branches along with the folder.
    private func selectableRows(_ details: RefDetails, _ branchRows: BranchRows) -> [(name: String, commit: ObjectID)] {
        var rows: [(name: String, commit: ObjectID)] = []
        if !isCollapsed(.branches) {
            rows += branchRows.local.compactMap(\.branch).map { ($0.name, $0.tip) }
        }
        if !isCollapsed(.remotes) {
            rows += details.remotes.flatMap { remote in
                (branchRows.remotes[remote.name] ?? []).compactMap(\.branch).map { ($0.name, $0.tip) }
            }
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

    /// The folders that are closed, though a filter opens the ones it has
    /// matches in.
    private var closedFolders: Set<String> {
        Set(collapsedFolders.split(separator: "\n").map(String.init))
    }

    private func setCollapsed(_ isCollapsed: Bool, folder ref: String) {
        var folders = closedFolders
        if isCollapsed { folders.insert(ref) } else { folders.remove(ref) }
        collapsedFolders = folders.sorted().joined(separator: "\n")
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
        Button("Filter Refs") { refs.showFilter() }
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
    let width: Double

    var body: some View {
        RefsNote("Choose a worktree to see its repository's refs.")
            .toolbar {
                // Holds the place of the panel's row, so that the button that
                // hides the panel stays next to it.
                ToolbarItem {
                    Color.clear
                        .frame(width: RefsPanelVisibility.toolbarItemWidth(panel: width), height: 1)
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }
}

/// A section's title with a chevron after it, and how many items it has.
/// Clicking it collapses or expands the section, unless it has nothing to show,
/// which leaves no chevron and nothing to click. It stays in place as the
/// section's rows scroll under it, so it has a background of its own.
private struct RefSectionHeader: View {
    let section: RefsModel.Section
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(section.title)
                .font(.system(size: 12, weight: .medium))
            if count > 0 {
                Chevron(pointsDown: !isCollapsed)
            }
            Spacer(minLength: 8)
            Text(count, format: .number)
                .font(.system(size: 11.5))
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: 28)
        .background(Palette.surface)
        .contentShape(Rectangle())
        .onTapGesture {
            if count > 0 { toggle() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(section.title)
        .accessibilityValue(count > 0 ? "\(count), \(isCollapsed ? "Collapsed" : "Expanded")" : "\(count)")
        .accessibilityHint(count > 0 ? "Shows or hides its rows" : "")
        .accessibilityAddTraits(count > 0 ? [.isHeader, .isButton] : .isHeader)
        .accessibilityAction(.default) {
            if count > 0 { toggle() }
        }
    }
}

/// A row in the panel. It fills with gray while the pointer is over it, if
/// clicking it does something, and a little darker while it's selected. A label
/// beside its first line gives way to its commands while the pointer is over
/// it, and its second line has the whole width.
private struct RefRow<Trailing: View, Commands: View>: View {
    let icon: Icon
    var imageColor = Color.secondary
    let title: String
    var subtitle: String?
    /// What right-clicking the row offers. Its header names the ref, so that it's
    /// clear what the menu acts on. A row with nothing to offer has no menu.
    var menu: [RefMenu.Entry] = []
    var isSelected = false
    /// How much further in than a section's rows it starts (`RefIndent`).
    var indent = 0.0
    var hasCommands = false
    var action: (() -> Void)?
    /// What double-clicking the row does, after its first click has done `action`.
    var doubleAction: (() -> Void)?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var commands: Commands
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon.image
                .font(.system(size: 13))
                .foregroundStyle(imageColor)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    // A title that doesn't fit fades out at its end
                    // (decision 51), and its tooltip has all of it.
                    FadingText(title)
                        .font(.system(size: 13))
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
        .padding(.leading, 8 + indent)
        .padding(.trailing, 8)
        .frame(height: subtitle == nil ? 28 : 40)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Palette.selection : isHovering && action != nil ? Palette.hover : .clear)
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .overlay {
            if !menu.isEmpty { RefMenuArea(entries: menu) }
        }
        .onTapGesture { action?() }
        // Alongside the single click rather than ahead of it, so that a click
        // doesn't wait to see whether a second one is coming.
        .simultaneousGesture(TapGesture(count: 2).onEnded { doubleAction?() })
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : action == nil ? [] : .isButton)
        .accessibilityAction(.default) { action?() }
        .accessibilityActions {
            if let doubleAction {
                Button("Check Out", action: doubleAction)
            }
            refMenuActions(menu)
        }
    }
}

/// How much further in than a section's rows a row starts: a step for its
/// remote, if it's a remote's branch, and one for each folder it's in. A step
/// puts a row's icon under the start of the name above it.
private enum RefIndent {
    static let step = 22.0

    static func of(_ depth: Int, isOnRemote: Bool = false) -> Double {
        Double(depth + (isOnRemote ? 1 : 0)) * step
    }
}

/// A remote, on one line: the cloud where a branch has its icon, the remote's
/// name, and its address in gray right after it, rather than at the right,
/// where its branches have their dates. On one line it's as tall as its
/// branches, so the section's rows are all one height. An address that doesn't
/// fit is cut short in the middle, which keeps its host and the repository's
/// name, and the tooltip has all of it.
private struct RefRemoteRow: View {
    let name: String
    /// Its address, or what to say when it has none.
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Icon.remote.image
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                FadingText(name)
                    .font(.system(size: 13))
                    .layoutPriority(1)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .padding(.horizontal, 6)
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(detail)
    }
}

/// A folder of branches (decision 50): a folder where a branch has its icon,
/// then the folder's name in gray with a chevron after it, as a section's
/// header and a repository in the sidebar have. Clicking it opens or closes it.
/// How many branches are under it is in its tooltip rather than on the row,
/// where it would line up with the dates and the counts of the branches.
private struct RefFolderRow: View {
    let name: String
    /// Its whole path, as in `origin/tm/`, for its tooltip.
    let path: String
    let count: Int
    let isCollapsed: Bool
    let indent: Double
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Icon.folder.image
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                FadingText(name)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Chevron(pointsDown: !isCollapsed)
            }
            Spacer(minLength: 8)
        }
        .padding(.leading, 8 + indent)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Palette.hover : .clear)
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { isHovering = $0 }
        .help("\(path) · \(branches)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(path)
        .accessibilityValue("\(branches), \(isCollapsed ? "Collapsed" : "Expanded")")
        .accessibilityHint("Shows or hides its branches")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, toggle)
    }

    private var branches: String {
        "\(count.formatted()) \(count == 1 ? "branch" : "branches")"
    }
}

/// How far a branch is from the one it's compared with, as arrows.
private struct AheadBehind: View {
    let ahead: Int
    let behind: Int

    var body: some View {
        HStack(spacing: 6) {
            if behind > 0 {
                Text("↓\(behind)")
                    .foregroundStyle(Palette.red)
            }
            if ahead > 0 {
                Text("↑\(ahead)")
                    .foregroundStyle(Palette.green)
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
    nonisolated static let defaultWidth = 288.0
    static let maximumWidth = 560.0
    /// How wide the middle of the window has to stay. The panels under history
    /// need 361 points of it.
    nonisolated static let minimumMiddleWidth = 400.0

    var isWanted: Binding<Bool>
    var fits: Bool

    var isShowing: Bool { isWanted.wrappedValue && fits }
    var commandTitle: String { isShowing ? "Hide Refs" : "Show Refs" }

    /// How much narrower than the panel its row in the toolbar is: the toolbar's
    /// margin at the edge of the window, measured on macOS 27, and what keeps the
    /// button before the row off the line between the panel and the middle.
    static let toolbarMargins = 14.0

    /// How wide the panel's row in the toolbar is.
    static func toolbarItemWidth(panel: Double) -> Double {
        panel - toolbarMargins
    }

    /// Whether the panel fits in the column it shares with the middle of the
    /// window, at its narrowest. The window works it out as it's laid out, away
    /// from the main actor.
    nonisolated static func fits(column: Double) -> Bool {
        column - defaultWidth >= minimumMiddleWidth
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
            Icon.panelRight.image
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
