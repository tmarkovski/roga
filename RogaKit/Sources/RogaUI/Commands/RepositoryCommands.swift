import CommitGraph
import GitCore
import SwiftUI

/// The menu commands for opening repositories and for their history.
public struct RepositoryCommands: Commands {
    let list: RepositoryList
    @FocusedValue(\.selection) private var selection
    @FocusedValue(\.repository) private var repository
    @FocusedValue(\.sidebarVisibility) private var sidebarVisibility
    @FocusedValue(\.deleteSelectedWorktree) private var deleteSelectedWorktree
    @FocusedValue(\.sidebarScope) private var sidebarScope
    @FocusedValue(\.showsOrganizationRail) private var showsOrganizationRail
    @FocusedValue(\.refsPanelVisibility) private var refsPanelVisibility
    @AppStorage(RefsPanelSettings.sort) private var refsSort = RefsModel.Sort.name
    @AppStorage(FileListSettings.layout) private var fileLayout = FileLayout.list
    @Environment(\.openWindow) private var openWindow

    /// The shortcut for opening a repository, which the sidebar shows too.
    static let openShortcut = KeyboardShortcut("o")
    /// The shortcut for deleting the worktree selected in the sidebar (decision 33).
    static let deleteWorktreeShortcut = KeyboardShortcut(.delete, modifiers: .command)
    /// The shortcut for copying the selected commit's hash, which the commit
    /// panel shows too.
    static let copyHashShortcut = KeyboardShortcut("c", modifiers: [.shift, .command])
    /// The shortcut for finding text in the diff, which the diff panel shows
    /// too.
    static let findShortcut = KeyboardShortcut("f")
    /// The shortcuts for going through what the diff panel found, which it
    /// shows too.
    static let findNextShortcut = KeyboardShortcut("g")
    static let findPreviousShortcut = KeyboardShortcut("g", modifiers: [.shift, .command])
    /// The shortcut for hiding the rail of organizations.
    static let organizationRailShortcut = KeyboardShortcut("o", modifiers: [.control, .command])
    /// The shortcut for hiding the refs panel, which is what macOS gives an
    /// inspector.
    static let refsPanelShortcut = KeyboardShortcut("i", modifiers: [.control, .command])
    /// The shortcut for going to the refs panel's filter.
    static let filterRefsShortcut = KeyboardShortcut("f", modifiers: [.option, .command])
    /// The shortcut for going to the filter for a commit's files, which the
    /// commit panel shows too.
    static let filterFilesShortcut = KeyboardShortcut("f", modifiers: [.shift, .command])
    /// The shortcuts for what can be done with the worktree's branch, which its
    /// menu in the title row shows too (decision 19).
    static let pullShortcut = KeyboardShortcut("l", modifiers: [.shift, .command])
    static let pushShortcut = KeyboardShortcut("p", modifiers: [.shift, .command])
    static let fetchShortcut = KeyboardShortcut("e", modifiers: [.shift, .command])
    static let newBranchShortcut = KeyboardShortcut("b", modifiers: [.shift, .command])

    /// The shortcuts for a worktree's uncommitted changes (decision 30).
    static let goToChangesShortcut = KeyboardShortcut("u", modifiers: [.shift, .command])
    static let stageShortcut = KeyboardShortcut("s")
    static let stageAllShortcut = KeyboardShortcut("s", modifiers: [.option, .command])
    static let unstageAllShortcut = KeyboardShortcut("s", modifiers: [.shift, .option, .command])
    static let writeMessageShortcut = KeyboardShortcut("l")
    static let commitShortcut = KeyboardShortcut(.return, modifiers: .command)
    static let commitAndPushShortcut = KeyboardShortcut(.return, modifiers: [.shift, .command])
    static let amendShortcut = KeyboardShortcut(.return, modifiers: [.option, .command])
    static let undoCommitShortcut = KeyboardShortcut("z", modifiers: [.option, .command])
    static let discardFileShortcut = KeyboardShortcut(.delete, modifiers: [.option, .command])
    static let discardAllShortcut = KeyboardShortcut(.delete, modifiers: [.shift, .option, .command])
    static let undoDiscardShortcut = KeyboardShortcut("z", modifiers: [.shift, .option, .command])

    public init(list: RepositoryList) {
        self.list = list
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open…") {
                let selection = selection
                openRepository(list: list) { selected in
                    // The repository shows in the focused window, or in a new
                    // one when no window is open.
                    if let selection {
                        selection.wrappedValue = selected
                    } else {
                        openWindow(value: WorkspaceWindow(selection: selected))
                    }
                }
            }
            .keyboardShortcut(Self.openShortcut)
            .disabled(!list.isConnected)
            Divider()
            Button("Delete Worktree…") {
                deleteSelectedWorktree?()
            }
            .keyboardShortcut(Self.deleteWorktreeShortcut)
            .disabled(deleteSelectedWorktree == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Commit Hash") {
                repository?.selectedCommit.copyHash()
            }
            .keyboardShortcut(Self.copyHashShortcut)
            .disabled(repository?.selectedCommit.id == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Diff…") {
                repository?.selectedFile.find()
            }
            .keyboardShortcut(Self.findShortcut)
            .disabled(repository?.selectedFile.canFind != true)
            Button("Find Next") {
                repository?.selectedFile.findNext()
            }
            .keyboardShortcut(Self.findNextShortcut)
            .disabled(repository?.selectedFile.hasMatches != true)
            Button("Find Previous") {
                repository?.selectedFile.findPrevious()
            }
            .keyboardShortcut(Self.findPreviousShortcut)
            .disabled(repository?.selectedFile.hasMatches != true)
        }
        CommandGroup(replacing: .sidebar) {
            Button(sidebarVisibility?.wrappedValue.sidebarCommandTitle ?? "Hide Sidebar") {
                sidebarVisibility?.wrappedValue.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(sidebarVisibility == nil)
            Button(showsOrganizationRail?.wrappedValue == false ? "Show Organizations" : "Hide Organizations") {
                showsOrganizationRail?.wrappedValue.toggle()
            }
            .keyboardShortcut(Self.organizationRailShortcut)
            .disabled(showsOrganizationRail == nil)
            Button(refsPanelVisibility?.commandTitle ?? "Hide Refs") {
                refsPanelVisibility?.isWanted.wrappedValue.toggle()
            }
            .keyboardShortcut(Self.refsPanelShortcut)
            .disabled(refsPanelVisibility?.fits != true)
            Button("Filter Refs") {
                refsPanelVisibility?.isWanted.wrappedValue = true
                repository?.refs.showFilter()
            }
            .keyboardShortcut(Self.filterRefsShortcut)
            .disabled(repository == nil || refsPanelVisibility?.fits != true)
            Picker("Sort Refs", selection: $refsSort) {
                ForEach(RefsModel.Sort.allCases, id: \.self) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            Divider()
            // Command-1 to Command-9 select what's on the rail.
            let groups = list.groups
            ForEach(Array(groups.scopes.prefix(9).enumerated()), id: \.element) { index, scope in
                Toggle(groups.title(of: scope), isOn: Binding {
                    sidebarScope?.wrappedValue == scope
                } set: { _ in
                    sidebarScope?.wrappedValue = scope
                })
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                .disabled(sidebarScope == nil)
            }
            Divider()
        }
        CommandGroup(before: .toolbar) {
            Picker("Order", selection: Binding(
                get: { repository?.sort ?? .topological },
                set: { repository?.sort = $0 }
            )) {
                Text("Topological Order").tag(HistoryOrder.Sort.topological)
                Text("Date Order").tag(HistoryOrder.Sort.date)
            }
            .pickerStyle(.inline)
            .disabled(repository == nil)
            Button("Reload") {
                repository?.reload()
                Task { await list.refresh() }
            }
            .keyboardShortcut("r")
            .disabled(!list.isConnected)
            Divider()
            // These work while the keyboard is in history, for going through a
            // commit's files without leaving it.
            Button("Next File") {
                repository?.selectFile(by: 1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            .disabled(repository?.selectedFile.file == nil)
            Button("Previous File") {
                repository?.selectFile(by: -1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            .disabled(repository?.selectedFile.file == nil)
            Button("Filter Files") {
                repository?.fileList.showFilter()
            }
            .keyboardShortcut(Self.filterFilesShortcut)
            .disabled(repository?.canFilterFiles != true)
            Picker("Show Files", selection: $fileLayout) {
                ForEach(FileLayout.allCases, id: \.self) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            Divider()
        }
        CommandMenu("Changes") {
            ChangesMenuItems(repository: repository)
        }
        CommandMenu("Branch") {
            if let branch = repository?.branch {
                BranchMenuItems(branch: branch, switchBranch: refsPanelVisibility?.fits == true ? {
                    refsPanelVisibility?.isWanted.wrappedValue = true
                    repository?.refs.showFilter()
                } : nil)
            } else {
                Button("Pull") {}
                    .keyboardShortcut(Self.pullShortcut)
                    .disabled(true)
                Button("Push") {}
                    .keyboardShortcut(Self.pushShortcut)
                    .disabled(true)
                Button("Fetch") {}
                    .keyboardShortcut(Self.fetchShortcut)
                    .disabled(true)
                Divider()
                Button("New Branch…") {}
                    .keyboardShortcut(Self.newBranchShortcut)
                    .disabled(true)
                Button("Switch Branch…") {}
                    .disabled(true)
            }
        }
    }
}

/// What can be done with a worktree's uncommitted changes (decision 30). It reads
/// the worktree's model in a view of its own, so that the menu follows it.
private struct ChangesMenuItems: View {
    let repository: RepositoryModel?

    private var changes: SelectedChanges? { repository?.selectedChanges }
    private var composer: CommitComposer? { repository?.composer }

    /// The selected file's group, while uncommitted changes are showing.
    private var group: WorktreeChanges.Group? {
        changes?.isSelected == true ? changes?.selectedFile.group : nil
    }

    private var discardFileTitle: String {
        guard let group, let file = changes?.selectedFile.file, let way = group.discarding(file) else { return FileDiscard.restore.fileTitle }
        return way.fileTitle
    }

    var body: some View {
        Button("Go to Uncommitted Changes") {
            repository?.goToChanges()
        }
        .keyboardShortcut(RepositoryCommands.goToChangesShortcut)
        .disabled(repository?.hasWorkingTreeRow != true)
        Divider()
        Button(group?.stageTitle ?? "Stage File") {
            changes?.toggleSelectedFile()
        }
        .keyboardShortcut(RepositoryCommands.stageShortcut)
        .disabled(group == nil)
        Button("Stage All") {
            changes?.toggleAll(in: group == .untracked ? .untracked : .unstaged)
        }
        .keyboardShortcut(RepositoryCommands.stageAllShortcut)
        .disabled(changes?.isSelected != true || (changes?.loaded?.unstaged.isEmpty != false && changes?.loaded?.untracked.isEmpty != false))
        Button("Unstage All") {
            changes?.toggleAll(in: .staged)
        }
        .keyboardShortcut(RepositoryCommands.unstageAllShortcut)
        .disabled(changes?.isSelected != true || changes?.loaded?.staged.isEmpty != false)
        Divider()
        Button(discardFileTitle) {
            changes?.discardSelectedFile()
        }
        .keyboardShortcut(RepositoryCommands.discardFileShortcut)
        .disabled(changes?.isSelected != true || changes?.canDiscardSelectedFile != true)
        Button("Discard All Changes…") {
            changes?.askToDiscardEverything()
        }
        .keyboardShortcut(RepositoryCommands.discardAllShortcut)
        .disabled(repository?.hasWorkingTreeRow != true || changes?.canDiscardEverything() != true)
        Button("Undo Discard") {
            changes?.undoDiscard()
        }
        .keyboardShortcut(RepositoryCommands.undoDiscardShortcut)
        .disabled(changes?.discards.isEmpty != false)
        Divider()
        Button("Write Commit Message") {
            composer?.askForFocus()
        }
        .keyboardShortcut(RepositoryCommands.writeMessageShortcut)
        .disabled(changes?.isSelected != true)
        Button(composer?.action.title ?? "Commit") {
            composer?.commit()
        }
        .keyboardShortcut(RepositoryCommands.commitShortcut)
        .disabled(changes?.isSelected != true || composer?.action.isEnabled != true)
        Button("Commit and Push") {
            composer?.commitAndPush()
        }
        .keyboardShortcut(RepositoryCommands.commitAndPushShortcut)
        .disabled(changes?.isSelected != true || composer?.action.isEnabled != true || composer?.stoppedWork != nil)
        Toggle("Amend", isOn: Binding { composer?.isAmending == true } set: { composer?.setAmending($0) })
            .keyboardShortcut(RepositoryCommands.amendShortcut)
            .disabled(changes?.isSelected != true || composer?.canAmend != true)
        Divider()
        Button("Undo Commit") {
            composer?.undoLastCommit()
        }
        .keyboardShortcut(RepositoryCommands.undoCommitShortcut)
        .disabled(composer?.lastCommit == nil || repository?.branch.isBusy == true)
    }
}
