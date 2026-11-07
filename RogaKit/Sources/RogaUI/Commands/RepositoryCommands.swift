import AgentEngine
import CommitGraph
import GitCore
import SwiftUI

/// The menu commands for opening repositories and for their history.
public struct RepositoryCommands: Commands {
    let list: RepositoryList
    /// The agents that write commit messages, for Generate's commands.
    let agents: AgentProvider
    @FocusedValue(\.selection) private var selection
    @FocusedValue(\.repository) private var repository
    @FocusedValue(\.sidebarVisibility) private var sidebarVisibility
    @FocusedValue(\.deleteSelectedWorktree) private var deleteSelectedWorktree
    @FocusedValue(\.refsPanelVisibility) private var refsPanelVisibility
    @FocusedValue(\.lowerPanelSize) private var lowerPanelSize
    @FocusedValue(\.openSettings) private var openSettings
    @AppStorage(RefsPanelSettings.sort) private var refsSort = RefsModel.Sort.name
    @AppStorage(SidebarSettings.groupsByOrganization) private var groupsByOrganization = true
    @AppStorage(SidebarSettings.sort) private var sidebarSort = SidebarSort.name
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
    /// The shortcut for grouping the sidebar's repositories by organization,
    /// which hid the rail of organizations before the groups replaced it.
    static let groupByOrganizationShortcut = KeyboardShortcut("o", modifiers: [.control, .command])
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
    /// Reviews the branch the worktree is on against the main branch (decision 54).
    static let reviewShortcut = KeyboardShortcut("r", modifiers: [.shift, .command])

    /// The shortcuts for a worktree's uncommitted changes (decision 30).
    static let goToChangesShortcut = KeyboardShortcut("u", modifiers: [.shift, .command])
    static let stageShortcut = KeyboardShortcut("s")
    static let stageAllShortcut = KeyboardShortcut("s", modifiers: [.option, .command])
    static let unstageAllShortcut = KeyboardShortcut("s", modifiers: [.shift, .option, .command])
    static let writeMessageShortcut = KeyboardShortcut("l")
    /// Has an agent write the message (decision 41), which pairs with Write
    /// Commit Message's Command-L. The Generate button's tooltip shows it too.
    static let generateMessageShortcut = KeyboardShortcut("l", modifiers: [.option, .command])
    static let commitShortcut = KeyboardShortcut(.return, modifiers: .command)
    static let commitAndPushShortcut = KeyboardShortcut(.return, modifiers: [.shift, .command])
    static let amendShortcut = KeyboardShortcut(.return, modifiers: [.option, .command])
    static let undoCommitShortcut = KeyboardShortcut("z", modifiers: [.option, .command])
    static let discardFileShortcut = KeyboardShortcut(.delete, modifiers: [.option, .command])
    static let discardAllShortcut = KeyboardShortcut(.delete, modifiers: [.shift, .option, .command])
    static let undoDiscardShortcut = KeyboardShortcut("z", modifiers: [.shift, .option, .command])

    public init(list: RepositoryList, agents: AgentProvider) {
        self.list = list
        self.agents = agents
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
            .disabled(repository?.selectedCommit.hashToCopy == nil)
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
            Toggle("Group Repositories by Organization", isOn: $groupsByOrganization)
                .keyboardShortcut(Self.groupByOrganizationShortcut)
            Picker("Sort Repositories", selection: $sidebarSort) {
                ForEach(SidebarSort.allCases, id: \.self) { sort in
                    Text(sort.title).tag(sort)
                }
            }
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
            // A step at a time, the way the arrows point: up from minimized
            // goes back to the panels' height, and from there covers history.
            let size = lowerPanelSize?.wrappedValue ?? .regular
            Button(size.tallerTitle) {
                if let taller = size.taller { lowerPanelSize?.wrappedValue = taller }
            }
            .keyboardShortcut(LowerPanelSize.tallerShortcut)
            .disabled(lowerPanelSize == nil || size.taller == nil)
            Button(size.shorterTitle) {
                if let shorter = size.shorter { lowerPanelSize?.wrappedValue = shorter }
            }
            .keyboardShortcut(LowerPanelSize.shorterShortcut)
            .disabled(lowerPanelSize == nil || size.shorter == nil)
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
            ChangesMenuItems(repository: repository, agents: agents, openSettings: openSettings)
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
            Divider()
            // It names the branch it compares with, as the refs panel's button does.
            let base = repository?.currentReviewBase
            Button(base.map { "Review Against \($0)" } ?? "Review Branch") {
                repository?.reviewCurrentBranch()
            }
            .keyboardShortcut(Self.reviewShortcut)
            .disabled(base == nil)
        }
    }
}

extension RepositoryCommands {
    /// An agent in the Changes menu's Generate With (decision 41).
    struct GenerateWithItem: Equatable {
        var kind: AgentKind
        /// The agent and its model, as in "Claude Code · haiku". With the
        /// agent's own default, that's Codex's model from its `config.toml`
        /// when Roga could read it, and otherwise the agent alone.
        var title: String
        /// Whether it's the one Generate runs, which a checkmark shows.
        var isCurrent: Bool
    }

    /// What Generate With lists: each agent Roga can run, in the order Settings
    /// lists them.
    static func generateWithItems(_ agents: AgentProvider) -> [GenerateWithItem] {
        let current = agents.generateAgent
        return agents.usableAgents.map { kind in
            var model = agents.settings[kind]?.model ?? kind.recommendedModel
            if model.isEmpty, kind == .codex, let known = agents.codexDefaultModel { model = known }
            return GenerateWithItem(kind: kind, title: GenerationSetup.label(kind, model: model), isCurrent: kind == current)
        }
    }
}

/// What can be done with a worktree's uncommitted changes (decision 30). It reads
/// the worktree's model in a view of its own, so that the menu follows it.
private struct ChangesMenuItems: View {
    let repository: RepositoryModel?
    let agents: AgentProvider
    let openSettings: ShowSettingsAction?

    private var changes: SelectedChanges? { repository?.selectedChanges }
    private var composer: CommitComposer? { repository?.composer }

    /// The selected file's group, while uncommitted changes are showing.
    private var group: WorktreeChanges.Group? {
        changes?.isSelected == true ? changes?.selectedFile.group : nil
    }

    /// Whether an agent can write the message now, which needs the changes'
    /// row to be showing, something to describe, and nothing else under way.
    private var canGenerate: Bool {
        changes?.isSelected == true && composer?.generator.readiness == .ready
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
        Button("Generate Message") {
            composer?.generator.generate(with: agents.generation())
        }
        .keyboardShortcut(RepositoryCommands.generateMessageShortcut)
        .disabled(!canGenerate || agents.generateAgent == nil)
        Menu("Generate With") {
            // Choosing an agent makes it the one Generate runs, and runs it.
            ForEach(RepositoryCommands.generateWithItems(agents), id: \.kind) { item in
                Toggle(item.title, isOn: Binding { item.isCurrent } set: { _ in
                    agents.setGenerateAgent(item.kind)
                    composer?.generator.generate(with: agents.generation(with: item.kind))
                })
                .disabled(!canGenerate)
            }
            Divider()
            Button("Agent Settings…") {
                openSettings?(.page(.commit))
            }
            .disabled(openSettings == nil)
        }
        // The message's items are a group of their own, apart from making the
        // commit, as the canvas's Changes menu has them.
        Divider()
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
            .disabled(changes?.isSelected != true || composer?.canAmend != true || composer?.generator.isWriting == true)
        Divider()
        Button("Undo Commit") {
            composer?.undoLastCommit()
        }
        .keyboardShortcut(RepositoryCommands.undoCommitShortcut)
        .disabled(composer?.lastCommit == nil || repository?.branch.isBusy == true)
    }
}
