import CommitGraph
import SwiftUI

/// The menu commands for opening repositories and for their history.
public struct RepositoryCommands: Commands {
    @FocusedBinding(\.emptyWindowPath) private var emptyWindowPath
    @FocusedValue(\.repository) private var repository
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open…") {
                guard let folder = chooseRepositoryFolder() else { return }
                // The value is nil when the focused window isn't empty, and
                // nil inside when it is.
                if emptyWindowPath != nil {
                    emptyWindowPath = folder
                } else {
                    openWindow(value: folder)
                }
            }
            .keyboardShortcut("o")
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
            Button("Reload History") { repository?.reload() }
                .keyboardShortcut("r")
                .disabled(repository == nil)
            Divider()
        }
    }
}
