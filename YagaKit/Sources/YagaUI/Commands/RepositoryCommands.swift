import CommitGraph
import SwiftUI

/// The menu commands for opening repositories and for their history.
public struct RepositoryCommands: Commands {
    let list: RepositoryList
    @FocusedValue(\.selection) private var selection
    @FocusedValue(\.repository) private var repository
    @FocusedValue(\.sidebarVisibility) private var sidebarVisibility
    @FocusedValue(\.sidebarScope) private var sidebarScope
    @FocusedValue(\.showsOrganizationRail) private var showsOrganizationRail
    @FocusedValue(\.refsPanelVisibility) private var refsPanelVisibility
    @AppStorage(RefsPanelSettings.sort) private var refsSort = RefsModel.Sort.name
    @Environment(\.openWindow) private var openWindow

    /// The shortcut for opening a repository, which the sidebar shows too.
    static let openShortcut = KeyboardShortcut("o")
    /// The shortcut for copying the selected commit's hash, which the commit
    /// panel shows too.
    static let copyHashShortcut = KeyboardShortcut("c", modifiers: [.shift, .command])
    /// The shortcut for finding text in the diff, which the diff panel shows
    /// too.
    static let findShortcut = KeyboardShortcut("f")
    /// The shortcut for hiding the rail of organizations.
    static let organizationRailShortcut = KeyboardShortcut("o", modifiers: [.control, .command])
    /// The shortcut for hiding the refs panel, which is what macOS gives an
    /// inspector.
    static let refsPanelShortcut = KeyboardShortcut("i", modifiers: [.control, .command])
    /// The shortcut for going to the refs panel's filter.
    static let filterRefsShortcut = KeyboardShortcut("f", modifiers: [.option, .command])

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
            Divider()
        }
    }
}
