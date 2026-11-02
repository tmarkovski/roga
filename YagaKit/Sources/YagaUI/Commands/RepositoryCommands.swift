import CommitGraph
import SwiftUI

/// The menu commands for opening repositories and for their history.
public struct RepositoryCommands: Commands {
    let list: RepositoryList
    @FocusedValue(\.selection) private var selection
    @FocusedValue(\.repository) private var repository
    @FocusedValue(\.sidebarVisibility) private var sidebarVisibility
    @Environment(\.openWindow) private var openWindow

    /// The shortcut for opening a repository, which the sidebar shows too.
    static let openShortcut = KeyboardShortcut("o")
    /// The shortcut for copying the selected commit's hash, which the commit
    /// panel shows too.
    static let copyHashShortcut = KeyboardShortcut("c", modifiers: [.shift, .command])

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
        CommandGroup(replacing: .sidebar) {
            Button(sidebarVisibility?.wrappedValue.sidebarCommandTitle ?? "Hide Sidebar") {
                sidebarVisibility?.wrappedValue.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(sidebarVisibility == nil)
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
        }
    }
}
