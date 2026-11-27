import AppKit
import GitCore
import IconUI
import MenuUI
import SwiftUI

/// The panel on the right of the window, which lists the repository's branches,
/// remotes, tags and stashes, and the worktree's submodules (docs/main-window.md).
/// Clicking a ref selects its commit in history, and double-clicking a branch
/// checks it out, as double-clicking its badge there does. Command-click and
/// Shift-click pick several local branches, which their menu deletes together,
/// and a folder of local branches has a menu that deletes the branches in it
/// (decision 121).
///
/// It draws its own rows rather than using a `List`, for the same reason as the
/// sidebar: its rows swap their label for commands on hover. So it handles the
/// arrow keys itself.
struct RefsPanel: View {
    let model: RepositoryModel
    /// Whether the panel shows, for the button at the end of its row and Hide
    /// refs in its menu.
    let visibility: RefsPanelVisibility
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
    /// Opens the panel's menu for VoiceOver's press.
    @State private var menuOpener = RefMenuOpener()

    private var refs: RefsModel { model.refs }

    var body: some View {
        VStack(spacing: 0) {
            RefsPanelHeader { commands }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .task(id: model.refsChecks) {
                await refs.load()
            }
            // The submodules are the worktree's, and change with its files as
            // well as its refs, so they follow every look at it (decision 75).
            // Another worktree in the window is another panel, which reads its own.
            .onChange(of: model.worktreeLooks, initial: true) {
                refs.readSubmodules(asOf: model.worktreeLooks)
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
            moreMenu
            RefsPanelToggle(visibility: visibility)
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
                    let submodules = refs.shownSubmodules
                    if isFiltering, details.isEmpty, submodules.isEmpty {
                        Text("No refs match “\(refs.filter)”")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(16)
                            .frame(maxWidth: .infinity)
                    }
                    section(.branches, count: details.branches.count, command: deleteMergedCommand) {
                        ForEach(rows.local) { row in
                            switch row.content {
                            case .folder(let ref, let name, let count, let isCollapsed):
                                folderRow(ref: ref, name: name, count: count, isCollapsed: isCollapsed, depth: row.depth, menu: folderMenu(ref, in: details))
                            case .branch(let branch, let title):
                                branchRow(branch, title: title, depth: row.depth, isCurrent: branch.name == details.currentBranch, lists: details)
                            }
                        }
                    }
                    section(.remotes, count: details.remotes.count, command: SectionCommand(icon: .plus, help: "Add a remote") {
                        model.branch.remoteDraft = BranchModel.RemoteDraft()
                    }) {
                        let trackers = refs.trackers
                        ForEach(details.remotes, id: \.name) { remote in
                            RefRemoteRow(name: remote.name, detail: remote.address ?? "Remote configuration missing", menu: remoteMenu(remote))
                            ForEach(rows.remotes[remote.name] ?? []) { row in
                                switch row.content {
                                case .folder(let ref, let name, let count, let isCollapsed):
                                    folderRow(ref: ref, name: name, count: count, isCollapsed: isCollapsed, depth: row.depth)
                                case .branch(let branch, let title):
                                    remoteBranchRow(branch, title: title, depth: row.depth, trackers: trackers[branch.name] ?? [], current: details.currentBranch)
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
                    section(.submodules, count: submodules.count) {
                        ForEach(submodules, id: \.path) { submodule in
                            submoduleRow(submodule)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            // A scroll view reaches up under the title row, where the panel's
            // commands are, and draws over the panel's header, which comes
            // before it. So rows that went past a section's pinned header
            // showed over the header's gray, behind the commands. They stop at
            // the line instead.
            .clipped()
            // Names the row that the pointer lights up while it's out of view.
            // Each edge has its own, which takes no room until it shows, so
            // that nothing lies over the rows to take the pointer from them.
            .overlay(alignment: .top) { RefsPill(refs: refs, isBelow: false) }
            .overlay(alignment: .bottom) { RefsPill(refs: refs, isBelow: true) }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                step(by: press.key == .downArrow ? 1 : -1)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !refs.picked.isEmpty else { return .ignored }
                refs.clearPicked()
                return .handled
            }
            .onChange(of: refs.selectionSteps) {
                if let name = refs.selectedRef { scroller.scrollTo(name) }
            }
        }
    }

    /// The button on the Branches heading that deletes the merged branches no
    /// worktree has, while there are any (decision 119).
    private var deleteMergedCommand: SectionCommand? {
        let merged = refs.deletableMergedBranches
        guard !merged.isEmpty, let main = merged.first?.main?.other else { return nil }
        let words = merged.count == 1 ? "Delete 1 merged branch…" : "Delete \(merged.count.formatted()) merged branches…"
        return SectionCommand(icon: .deleteBranch, help: words) {
            isListFocused = true
            model.branch.askToDelete(merged: merged.map(\.name), into: main)
        }
    }

    /// A section, unless it has nothing to show and no reason to stay.
    @ViewBuilder private func section<Rows: View>(_ section: RefsModel.Section, count: Int, command: SectionCommand? = nil, @ViewBuilder rows: () -> Rows) -> some View {
        if section.isShown(count: count, isFiltering: !refs.filter.isEmpty) {
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
                    RefSectionHeader(section: section, count: count, isCollapsed: isCollapsed, command: command) {
                        isListFocused = true
                        setCollapsed(!isCollapsed, section)
                    }
                }
            }
        }
    }

    /// A folder of branches, which opens and closes.
    private func folderRow(ref: String, name: String, count: Int, isCollapsed: Bool, depth: Int, menu: [RefMenu.Entry] = []) -> some View {
        RefFolderRow(name: name, path: Ref.shortName(ref), count: count, isCollapsed: isCollapsed, indent: RefIndent.of(depth), menu: menu) {
            isListFocused = true
            setCollapsed(!isCollapsed, folder: ref)
        }
        .id(ref)
    }

    /// What right-clicking a folder of local branches offers: deleting the
    /// branches in it that the panel lists, which a filter narrows as it narrows
    /// the folder (decision 121). A folder of a remote's branches has no menu.
    private func folderMenu(_ ref: String, in details: RefDetails) -> [RefMenu.Entry] {
        guard ref.hasPrefix(Ref.branchPrefix) else { return [] }
        let path = Ref.shortName(ref)
        let branches = details.branches.filter { $0.name.hasPrefix(ref) }
        return [
            .header(RefMenu.Title(path)),
            deleteSeveral(branches, current: details.currentBranch, as: .folder(path)),
        ]
    }

    /// What right-clicking one of the picked branches offers (decision 121).
    private func pickedMenu(in details: RefDetails) -> [RefMenu.Entry] {
        let branches = details.branches.filter { refs.picked.contains($0.name) }
        return [
            .header(RefMenu.Title("\(branches.count.formatted()) branches")),
            deleteSeveral(branches, current: details.currentBranch, as: .picked),
        ]
    }

    /// Deletes some local branches, after a dialog with a switch for each. Its
    /// count leaves out the ones git won't delete because they're checked out,
    /// and the main branch, which the dialog says stay.
    private func deleteSeveral(_ branches: [BranchDetails], current: String?, as kind: BranchModel.BranchChoice.Kind) -> RefMenu.Entry {
        let main = model.mainBranch
        let deletable = branches.filter { $0.name != current && $0.worktree == nil && $0.name != main }.count
        let title: RefMenu.Title = deletable == 1 ? "Delete 1 branch…" : "Delete \(deletable.formatted()) branches…"
        return .command(title, isDestructive: true, isEnabled: deletable > 0 && !model.branch.isBusy) {
            isListFocused = true
            model.branch.askToDelete(branches: branches.map(\.name), as: kind)
        }
    }

    /// A local branch, on one line (decision 119). Its icon says whose it is and
    /// where it's checked out: the current branch's green, or sky, and the icon
    /// of the tab of a worktree that has it. What it says after its name is in
    /// `BranchDetails.RowState`, and the rest is in its tooltip.
    ///
    /// - Parameter title: What's left of the branch's name after the folders
    ///   it's in.
    private func branchRow(_ branch: BranchDetails, title: String, depth: Int, isCurrent: Bool, lists: RefDetails) -> some View {
        let otherWorktree = isCurrent ? nil : branch.worktree
        let isPicked = refs.picked.contains(branch.name)
        let icon: Icon = if otherWorktree == nil { .branch } else if branch.isWorktreeLocked { .lock } else { .worktree }
        let details = branch.details(isCurrent: isCurrent)
        return RefRow(
            icon: icon,
            imageColor: isCurrent ? Palette.current : Palette.otherBranch,
            title: title,
            help: ([branch.shortName] + details).joined(separator: "\n"),
            accessibilityDetails: details.joined(separator: ", "),
            menu: isPicked ? pickedMenu(in: lists) : branchMenu(branch, isCurrent: isCurrent, otherWorktree: otherWorktree),
            isSelected: (refs.picked.isEmpty ? isSelected(branch.name, branch.tip) : isPicked) || model.reviewedBranch == branch.name,
            isDone: branch.isDone(isCurrent: isCurrent),
            indent: RefIndent.of(depth),
            linking: RefRowLinking(refs: refs, name: branch.name),
            hasCommands: otherWorktree != nil,
            action: { click(branch, in: lists) },
            // There's nothing to do for the current branch, as for its badge,
            // and a second click that picks isn't a double-click.
            doubleAction: isCurrent ? nil : {
                if !Self.clickModifiers.isDisjoint(with: [.command, .shift]) { return }
                checkOut(branch.name)
            }
        ) {
            BranchRowState(state: branch.rowState(isCurrent: isCurrent))
        } commands: {
            // Reviewing a branch is in its menu, and Branch > Review Against main
            // with Shift-Command-R for the one the worktree is on (decision 80).
            if let otherWorktree {
                Button { showWorktree(otherWorktree, branch.tip) } label: { Icon.worktree.image }
                    .buttonStyle(.icon(size: 24))
                    .help("Show Worktree")
                    .accessibilityLabel("Show Worktree")
            }
        }
        .id(branch.name)
    }

    /// Selects a local branch, or with Command or Shift, picks it along with
    /// others (decision 121). History shows the commit of the branch clicked
    /// last, or of the one that's left when Command-clicking leaves one.
    private func click(_ branch: BranchDetails, in details: RefDetails) {
        let modifiers = Self.clickModifiers
        guard !modifiers.isDisjoint(with: [.command, .shift]) else {
            select(branch.name, branch.tip)
            return
        }
        isListFocused = true
        let selected = refs.picked.isEmpty
            ? details.branches.first { $0.name == refs.selectedRef && isSelected($0.name, $0.tip) }?.name
            : nil
        if modifiers.contains(.shift) {
            let rows = refs.branchRows(sort: sort, collapsed: closedFolders)?.local.compactMap(\.branch?.name) ?? []
            refs.pick(through: branch.name, in: rows, selected: selected)
            model.select(commit: branch.tip)
        } else if refs.pick(toggling: branch.name, selected: selected) {
            model.select(commit: branch.tip)
        } else if refs.picked.isEmpty, let left = details.branches.first(where: { $0.name == refs.selectedRef }) {
            model.select(commit: left.tip)
        }
    }

    /// The keys held with the click being handled, from the click itself, as
    /// history's list reads them. `NSEvent.modifierFlags` has only the keys
    /// pressed at the moment, which a click that an assistive app sends with
    /// Command doesn't press.
    private static var clickModifiers: NSEvent.ModifierFlags {
        NSApp.currentEvent?.modifierFlags ?? []
    }

    private func review(_ name: String) {
        isListFocused = true
        model.review(branch: name)
    }

    private func branchMenu(_ branch: BranchDetails, isCurrent: Bool, otherWorktree: String?) -> [RefMenu.Entry] {
        model.menuEntries(
            forBranch: branch.name,
            tip: branch.tip,
            otherWorktree: otherWorktree,
            review: { review(branch.name) },
            // git won't delete a branch that a worktree has checked out.
            delete: HistoryMenu.Delete(title: "Delete branch", isEnabled: !isCurrent && branch.worktree == nil && !model.branch.isBusy) {
                model.branch.askToDelete(ref: branch.name)
            },
            showWorktree: showWorktree
        )
    }

    /// What right-clicking a remote offers. One that has branches left but isn't
    /// configured any more is something git can't remove.
    private func remoteMenu(_ remote: RemoteDetails) -> [RefMenu.Entry] {
        var rows: [RefMenu.Entry] = [
            .header(RefMenu.Title(remote.name)),
            .command("Add remote…") { model.branch.remoteDraft = BranchModel.RemoteDraft() },
        ]
        if remote.address != nil {
            rows += [.divider, .command("Remove…", isDestructive: true, isEnabled: !model.branch.isBusy) { model.askToRemove(remote: remote) }]
        }
        return rows
    }

    /// A remote branch, on one line. Its icon's color says whether a local
    /// branch tracks it, in the colors of that branch (decision 119), and its
    /// date is in its tooltip rather than at the end of its row.
    ///
    /// - Parameters:
    ///   - trackers: The local branches that track it.
    ///   - current: The full name of the branch checked out here.
    private func remoteBranchRow(_ branch: RemoteBranchDetails, title: String, depth: Int, trackers: [BranchDetails], current: String?) -> some View {
        let color: Color = if trackers.contains(where: { $0.name == current }) {
            Palette.current
        } else if trackers.isEmpty {
            .secondary
        } else {
            Palette.otherBranch
        }
        let details = branch.details(trackedBy: trackers.map(\.shortName))
        return RefRow(
            icon: .branch,
            imageColor: color,
            title: title,
            help: ([Ref.shortName(branch.name)] + details).joined(separator: "\n"),
            accessibilityDetails: details.joined(separator: ", "),
            // Its heading has the full name, because the row's title leaves out the remote.
            menu: model.menuEntries(
                forBranch: branch.name,
                tip: branch.tip,
                delete: HistoryMenu.Delete(title: "Delete from remote…", isEnabled: !model.branch.isBusy) {
                    model.branch.askToDelete(ref: branch.name)
                },
                showWorktree: showWorktree
            ),
            isSelected: isSelected(branch.name, branch.tip),
            isDone: branch.isMerged,
            indent: RefIndent.of(depth),
            linking: RefRowLinking(refs: refs, name: branch.name),
            action: { select(branch.name, branch.tip) },
            doubleAction: { checkOut(branch.name) }
        ) {
            BranchRowState(state: branch.isMerged ? .merged : .quiet)
        } commands: {
        }
        .id(branch.name)
    }

    /// A tag on a commit has the menu its badge in history has. One on something
    /// else, such as a tree, can only be copied. Whether `HEAD` has the commit is
    /// only looked for as the menu opens, because that walks history.
    private func tagRow(_ tag: TagDetails) -> some View {
        RefRow(
            icon: .tag,
            title: tag.shortName,
            subtitle: tag.subject ?? "No commit to show",
            menu: tag.commit.map { model.menuEntries(forTag: tag.name, commit: $0, looksForHead: false, showWorktree: showWorktree) } ?? [
                .header(RefMenu.Title(tag.shortName)),
                .command("Copy name") { copy(tag.shortName) },
            ],
            menuOnOpen: tag.commit.map { commit in { model.menuEntries(forTag: tag.name, commit: commit, showWorktree: showWorktree) } },
            isSelected: tag.commit.map { isSelected(tag.name, $0) } ?? false,
            action: tag.commit.map { commit in { select(tag.name, commit) } }
        ) {
        } commands: {
        }
        .id(tag.name)
    }

    /// A stash, which shows what it holds in the panels (decision 56). Its row
    /// leaves out the branch git puts at the start of its message, and names it
    /// on the second line instead (decision 81).
    private func stashRow(_ stash: StashDetails) -> some View {
        RefRow(
            icon: .stash,
            title: stash.rowTitle,
            subtitle: stash.subtitle(),
            menu: stashMenu(stash),
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

    /// What right-clicking a stash offers, in plain words rather than git's pop
    /// and apply (decision 81).
    private func stashMenu(_ stash: StashDetails) -> [RefMenu.Entry] {
        let isBusy = model.branch.isBusy
        return [
            .header(RefMenu.Title(stash.rowTitle)),
            .command("Pop stash", isEnabled: !isBusy) { model.putBack(stash) },
            .command("Apply stash", isEnabled: !isBusy) { model.putBack(stash, keeping: true) },
            .divider,
            .command("New branch from stash…", isEnabled: !isBusy) { model.branch.startNewBranch(fromStash: stash, from: MenuAnchor.current) },
            .command("Copy message") { copy(stash.title) },
            .divider,
            .command("Delete", isDestructive: true, isEnabled: !isBusy) { model.delete(stash) },
        ]
    }

    /// One of the worktree's submodules, which shows where it stands in the
    /// panels (decision 75). One that isn't checked out in the worktree is
    /// dimmed.
    private func submoduleRow(_ submodule: Submodule) -> some View {
        RefRow(
            icon: .box,
            title: submodule.path,
            subtitle: submodule.subtitle,
            isSelected: model.selectedCommit.submodule?.path == submodule.path,
            isDimmed: submodule.checkedOut == nil,
            action: {
                isListFocused = true
                model.select(submodule: submodule)
            }
        ) {
            SubmoduleCounts(submodule: submodule)
        } commands: {
        }
        .id(submodule.refsRow)
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
    /// remotes, stashes and submodules, which have no commit in history.
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

    /// The button with the panel's menu. It's one of Roga's own menus, like
    /// the sidebar's Group and Sort, so how the refs are sorted is a submenu
    /// that says which, rather than a button of its own (decision 87).
    private var moreMenu: some View {
        let entries = panelMenu
        return HoverIcon { Icon.ellipsis.image }
            .overlay { RefMenuArea(entries: entries, opensOnClick: true, opener: menuOpener) }
            .help("More")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("More")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { menuOpener.open() }
            .accessibilityActions { refMenuActions(entries) }
    }

    private var panelMenu: [RefMenu.Entry] {
        Self.panelMenu(
            sort: sort,
            setSort: { sort = $0 },
            filter: { refs.showFilter() },
            collapseAll: { collapsedSections = RefsModel.Section.allCases.map(\.rawValue).joined(separator: ",") },
            expandAll: { collapsedSections = "" },
            hide: { visibility.isWanted.wrappedValue = false }
        )
    }

    /// The panel's menu: how the refs are sorted, in a submenu that says which,
    /// then its commands, with the keys the menu bar has for them.
    static func panelMenu(
        sort: RefsModel.Sort,
        setSort: @escaping (RefsModel.Sort) -> Void,
        filter: @escaping () -> Void,
        collapseAll: @escaping () -> Void,
        expandAll: @escaping () -> Void,
        hide: @escaping () -> Void
    ) -> [RefMenu.Entry] {
        [
            .submenu("Sort by", value: sort.title, entries: RefsModel.Sort.allCases.map { option in
                .option(RefMenu.Title(option.title), isChecked: sort == option) { setSort(option) }
            }),
            .divider,
            .command("Filter refs", shortcut: RefMenu.Shortcut(RepositoryCommands.filterRefsShortcut), action: filter),
            .command("Collapse all sections", action: collapseAll),
            .command("Expand all sections", action: expandAll),
            .divider,
            .command("Hide refs", shortcut: RefMenu.Shortcut(RepositoryCommands.refsPanelShortcut), action: hide),
        ]
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
    let visibility: RefsPanelVisibility

    var body: some View {
        VStack(spacing: 0) {
            // The panel's header, with the button that hides the panel at its
            // end, as the panel has it.
            RefsPanelHeader {
                RefsPanelToggle(visibility: visibility)
            }
            RefsNote("Choose a worktree to see its repository's refs.")
        }
    }
}

/// The panel's row at the top of the window, beside the title row and as tall
/// (decision 96), and in its gray, so that the band along the top runs across
/// both (decision 95). Its commands are at its end, and the button that hides
/// the panel is its last, in the window's corner, where the title row has it
/// while the panel is hidden (decision 85).
private struct RefsPanelHeader<Commands: View>: View {
    @ViewBuilder var commands: Commands

    var body: some View {
        HStack(spacing: 4) {
            commands
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 10)
        .padding(.trailing, TitleBar.trailingInset)
        .frame(height: TitleBar.height)
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
    }
}

/// A command at the right of a section's heading: the plus that adds a remote,
/// and on Branches, the button that deletes the merged branches (decision 119).
struct SectionCommand {
    let icon: Icon
    /// Its tooltip and its name for VoiceOver.
    let help: String
    let action: () -> Void
}

/// A section's title with a chevron after it, and at its right, the section's
/// command, if it has one. Clicking it collapses or expands the section, unless it
/// has nothing to show, which leaves no chevron and nothing to click. It stays
/// in place as the section's rows scroll under it, so it has a background of
/// its own.
private struct RefSectionHeader: View {
    let section: RefsModel.Section
    let count: Int
    let isCollapsed: Bool
    var command: SectionCommand?
    let toggle: () -> Void

    /// How far the icon is from the right of its box: it's about 9 points wide
    /// at its size, in a box of 22.
    private static let iconInset = 6.0

    var body: some View {
        HStack(spacing: 4) {
            Text(section.title)
                .font(.system(size: 12, weight: .medium))
            if count > 0 {
                Chevron(pointsDown: !isCollapsed)
            }
            Spacer(minLength: 8)
            // The header's right is for its commands. It shows no count, which
            // would read like the numbers that ask for something, such as
            // commits to pull (decision 84).
            if let command {
                Button(action: command.action) {
                    HoverIcon(size: 22) { command.icon.image }
                }
                .buttonStyle(.plain)
                .help(command.help)
                // The icon is in the middle of a box that's wider than it,
                // which is what turns gray under the pointer. The box goes
                // past the line the rows' labels end on, so that the icon
                // itself ends on that line.
                .padding(.trailing, -Self.iconInset)
            }
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
        // How many it has is in its tooltip, as a folder's is.
        .help(section.counted(count))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(section.title)
        .accessibilityValue(count > 0 ? "\(count), \(isCollapsed ? "Collapsed" : "Expanded")" : "\(count)")
        .accessibilityHint(count > 0 ? "Shows or hides its rows" : "")
        .accessibilityAddTraits(count > 0 ? [.isHeader, .isButton] : .isHeader)
        .accessibilityAction(.default) {
            if count > 0 { toggle() }
        }
        .accessibilityActions {
            if let command { Button(command.help, action: command.action) }
        }
    }
}

/// The size of a row's icon and the room around it (decision 119): a 12-point
/// column with 6 points after it, where it used to be 16 with 8, so that a row
/// in a folder under a remote has room for its name.
private enum RefIcon {
    /// The size of the font the icon is drawn at.
    static let size = 11.0
    static let width = 14.0
    static let gap = 6.0
}

/// How a row that the pointer can rest on takes part in lighting up what goes
/// with it (decision 119): it says when the pointer is on it and whether it's
/// in view, and it tints while something else lights it up.
struct RefRowLinking {
    let refs: RefsModel
    /// The branch's full name.
    let name: String
}

/// A row in the panel. It fills with gray while the pointer is over it, if
/// clicking it does something, and a little darker while it's selected. A label
/// beside its first line gives way to its commands while the pointer is over
/// it. They sit at the right, in the middle of the row's height rather than on
/// its first line, so that a two-line row leaves room above and below them,
/// and both lines make room for them.
private struct RefRow<Trailing: View, Commands: View>: View {
    let icon: Icon
    var imageColor = Color.secondary
    let title: String
    var subtitle: String?
    /// Its tooltip, when it says more than the title does. The tooltip is the
    /// title's alone, so that a command's button shows its own.
    var help: String?
    /// What VoiceOver reads after the title, for a row whose second line is in
    /// its tooltip.
    var accessibilityDetails: String?
    /// What right-clicking the row offers. Its header names the ref, so that it's
    /// clear what the menu acts on. A row with nothing to offer has no menu.
    var menu: [RefMenu.Entry] = []
    /// Builds the menu again as it opens, when it needs something that's too slow
    /// to find out whenever the row is drawn. Assistive apps get `menu`.
    var menuOnOpen: (() -> [RefMenu.Entry])?
    var isSelected = false
    /// Whether its icon and title are gray, for something that's listed and
    /// isn't there, such as a submodule that isn't checked out.
    var isDimmed = false
    /// Whether its title alone is gray, for a branch that's merged and done
    /// with. Its icon keeps its color, which says whose it is.
    var isDone = false
    /// How much further in than a section's rows it starts (`RefIndent`).
    var indent = 0.0
    var linking: RefRowLinking?
    var hasCommands = false
    var action: (() -> Void)?
    /// What double-clicking the row does, after its first click has done `action`.
    var doubleAction: (() -> Void)?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var commands: Commands
    @State private var isHovering = false

    var body: some View {
        let showsCommands = isHovering && hasCommands
        HStack(spacing: RefIcon.gap) {
            icon.image
                .font(.system(size: RefIcon.size))
                .foregroundStyle(isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(imageColor))
                .frame(width: RefIcon.width)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    // A title that doesn't fit fades out at its end
                    // (decision 51).
                    FadingText(title)
                        .font(.system(size: 13))
                        .foregroundStyle(isDimmed || isDone ? .secondary : .primary)
                        .help(help ?? title)
                    Spacer(minLength: 0)
                    if !showsCommands {
                        HStack(spacing: 0) { trailing }
                            .frame(height: 16)
                    }
                }
                if let subtitle {
                    // It gives way to the commands on hover, so it fades out
                    // before them rather than being cut short (decision 114).
                    FadingText(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            if showsCommands {
                // Shorter than the row, so it moves no text up or down.
                HStack(spacing: 0) { commands }
            }
        }
        .padding(.leading, 8 + indent)
        .padding(.trailing, 8)
        .frame(height: subtitle == nil ? 28 : 40)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fill)
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .overlay {
            if !menu.isEmpty { RefMenuArea(entries: menu, entriesOnOpen: menuOnOpen) }
        }
        .onTapGesture { action?() }
        // Alongside the single click rather than ahead of it, so that a click
        // doesn't wait to see whether a second one is coming.
        .simultaneousGesture(TapGesture(count: 2).onEnded { doubleAction?() })
        .onHover { isHovering in
            self.isHovering = isHovering
            guard let linking else { return }
            if isHovering {
                linking.refs.point(at: .ref(linking.name))
            } else {
                linking.refs.stopPointing(at: .ref(linking.name))
            }
        }
        .modifier(ReportsVisibility(linking: linking))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle ?? accessibilityDetails ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : action == nil ? [] : .isButton)
        .accessibilityAction(.default) { action?() }
        .accessibilityActions {
            if let doubleAction {
                Button("Check Out", action: doubleAction)
            }
            refMenuActions(menu)
        }
    }

    /// Selected, then lit up by what the pointer rests on elsewhere, then
    /// under the pointer.
    private var fill: Color {
        if isSelected { return Palette.selection }
        if let linking, let color = linking.refs.linkTint(for: linking.name) { return color }
        return isHovering && action != nil ? Palette.hover : .clear
    }
}

/// Tells the panel's model whether a row that can light up is in view, which
/// says whether the pill names it.
private struct ReportsVisibility: ViewModifier {
    let linking: RefRowLinking?

    func body(content: Content) -> some View {
        if let linking {
            content
                .onScrollVisibilityChange(threshold: 0.6) { linking.refs.setVisible($0, ref: linking.name) }
                .onDisappear { linking.refs.setVisible(false, ref: linking.name) }
        } else {
            content
        }
    }
}

/// How much further in than a section's rows a row starts: a step for each
/// folder it's in. A remote's branches start where the local ones do, rather
/// than a step further in under the remote, so that a branch and its remote
/// copy line up (decision 119).
private enum RefIndent {
    static let step = 16.0

    static func of(_ depth: Int) -> Double {
        Double(depth) * step
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
    /// What right-clicking it offers.
    let menu: [RefMenu.Entry]

    var body: some View {
        HStack(spacing: RefIcon.gap) {
            Icon.remote.image
                .font(.system(size: RefIcon.size))
                .foregroundStyle(.secondary)
                .frame(width: RefIcon.width)
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
        .contentShape(Rectangle())
        .overlay { RefMenuArea(entries: menu) }
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(detail)
        .accessibilityActions { refMenuActions(menu) }
    }
}

/// A folder of branches (decision 50): a folder where a branch has its icon,
/// then the folder's name in gray with a chevron after it, as a section's
/// header and a repository in the sidebar have. Clicking it opens or closes it.
/// How many branches are under it is in its tooltip rather than on the row,
/// where it would line up with the counts of the branches. A folder of local
/// branches has a menu that deletes them (decision 121).
private struct RefFolderRow: View {
    let name: String
    /// Its whole path, as in `origin/tm/`, for its tooltip.
    let path: String
    let count: Int
    let isCollapsed: Bool
    let indent: Double
    /// What right-clicking it offers. A folder with nothing to offer has no menu.
    var menu: [RefMenu.Entry] = []
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: RefIcon.gap) {
            Icon.folder.image
                .font(.system(size: RefIcon.size))
                .foregroundStyle(.secondary)
                .frame(width: RefIcon.width)
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
        .overlay {
            if !menu.isEmpty { RefMenuArea(entries: menu) }
        }
        .onTapGesture(perform: toggle)
        .onHover { isHovering = $0 }
        .help("\(path) · \(branches)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(path)
        .accessibilityValue("\(branches), \(isCollapsed ? "Collapsed" : "Expanded")")
        .accessibilityHint("Shows or hides its branches")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, toggle)
        .accessibilityActions { refMenuActions(menu) }
    }

    private var branches: String {
        "\(count.formatted()) \(count == 1 ? "branch" : "branches")"
    }
}

/// What a branch's row says after its name (decision 119): a checkmark for the
/// branch checked out here, its counts, or that it's merged.
private struct BranchRowState: View {
    let state: BranchDetails.RowState

    var body: some View {
        switch state {
        case .checkedOut:
            Icon.check.image
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Checked out")
        case .counts(let behind, let ahead):
            AheadBehind(ahead: ahead, behind: behind)
        case .merged:
            Text("merged")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        case .quiet:
            EmptyView()
        }
    }
}

/// How far a branch is from the one it's compared with, as arrows, in gray as
/// a worktree's tab has them, since clicking the row selects it rather than
/// pulling or pushing (decision 119).
private struct AheadBehind: View {
    let ahead: Int
    let behind: Int

    var body: some View {
        HStack(spacing: 5) {
            if behind > 0 {
                Text("↓" + behind.formatted())
            }
            if ahead > 0 {
                Text("↑" + ahead.formatted())
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// The pill at the edge of the list that names the row the pointer lights up
/// while that row is out of view, with an arrow toward it (decision 119). It
/// takes no clicks, so it never gets in the way of the rows under it.
private struct RefsPill: View {
    let refs: RefsModel
    /// Which edge this one is at: the bottom, for a row below the ones in view.
    let isBelow: Bool

    /// How tall a section's heading is (`RefSectionHeader`).
    private static let headingHeight = 28.0

    var body: some View {
        let pill = refs.pill.flatMap { $0.isBelow == isBelow ? $0 : nil }
        ZStack {
            if let pill {
                let color = pill.isCurrent ? Palette.current : Palette.otherBranch
                HStack(spacing: 5) {
                    // The arrows the counts have.
                    Text(isBelow ? "↓" : "↑")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                    Text(pill.name)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .frame(height: 24)
                .background(Capsule().fill(Palette.surface))
                .overlay(Capsule().strokeBorder(color, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                .padding(.horizontal, 16)
                // At the top, below the section's heading, which stays there
                // as the rows scroll.
                .padding(.top, isBelow ? 0 : Self.headingHeight + 4)
                .padding(.bottom, isBelow ? 8 : 0)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: pill)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// How a submodule's checkout stands against what's recorded, beside its name:
/// the commits it's missing and the ones it has that aren't recorded, as a
/// branch has them, and how many uncommitted files it has, in the orange that
/// counts of uncommitted files have everywhere (decision 75). The row's second
/// line says the same in words, which is what VoiceOver reads.
private struct SubmoduleCounts: View {
    let submodule: Submodule

    var body: some View {
        let counts = submodule.counts
        HStack(spacing: 6) {
            AheadBehind(ahead: counts.ahead, behind: counts.behind)
            if counts.files > 0 {
                Text(counts.files, format: .number)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.orange)
            }
        }
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

    /// Whether the panel fits in the column it shares with the middle of the
    /// window, at its narrowest. The window works it out as it's laid out, away
    /// from the main actor.
    nonisolated static func fits(column: Double) -> Bool {
        column - defaultWidth >= minimumMiddleWidth
    }
}

/// Hides or shows the refs panel. It's a plain icon like the button for the
/// sidebar, rather than the glass button macOS puts in the toolbar.
///
/// It's last in the title row, in the window's top right corner: the last of
/// the panel's own buttons while the panel shows, and the title row's last
/// while it's hidden. So it doesn't move when it's clicked, as the sidebar's
/// stays by the traffic lights (decision 85).
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
