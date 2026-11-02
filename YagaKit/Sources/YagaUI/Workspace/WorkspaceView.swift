import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import SwiftUI

/// What a window shows, which SwiftUI saves with the window. Each window has
/// an ID of its own, so that opening a worktree in a new window opens one
/// even when another window shows that worktree.
public struct WorkspaceWindow: Codable, Hashable, Sendable {
    public var id = UUID()
    public var selection: WorktreeSelection?

    public init(selection: WorktreeSelection? = nil) {
        self.selection = selection
    }
}

/// The contents of a yaga window: the sidebar, and the worktree selected in
/// it.
public struct WorkspaceView: View {
    @Binding var window: WorkspaceWindow?
    @Environment(GitProvider.self) private var gitProvider
    @Environment(RepositoryList.self) private var list
    @State private var recent = RecentWorktrees()
    @State private var columns = NavigationSplitViewVisibility.all

    public init(window: Binding<WorkspaceWindow?>) {
        _window = window
    }

    private var selection: Binding<WorktreeSelection?> {
        Binding {
            window?.selection
        } set: { selection in
            var changed = window ?? WorkspaceWindow()
            changed.selection = selection
            window = changed
        }
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(list: list, selection: selection, open: open, locate: locate)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
                .overlay(alignment: .trailing) {
                    // A line between the sidebar and the worktree, from the
                    // top of the window to the bottom.
                    Rectangle()
                        .fill(Palette.separator)
                        .frame(width: 1)
                        .ignoresSafeArea()
                }
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    // macOS keeps the sidebar's toolbar items next to the
                    // traffic lights while the sidebar is hidden.
                    ToolbarItem {
                        SidebarToggle(visibility: $columns)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
        } detail: {
            detail
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .frame(minWidth: 720, minHeight: 480)
        .task(id: gitProvider.git != nil) {
            if let git = gitProvider.git { await list.connect(git: git) }
        }
        .onAppear {
            // A new window, or one macOS didn't restore, shows the worktree
            // selected last.
            if window?.selection == nil { selection.wrappedValue = list.lastSelection }
        }
        .onChange(of: window?.selection) { _, selected in
            if let selected { list.lastSelection = selected }
        }
        .onChange(of: list.resolve(window?.selection)) { _, resolved in
            if resolved != window?.selection { selection.wrappedValue = resolved }
        }
        .focusedSceneValue(\.selection, selection)
        .focusedSceneValue(\.sidebarVisibility, $columns)
    }

    @ViewBuilder private var detail: some View {
        switch gitProvider.state {
        case .locating:
            ProgressView()
                .controlSize(.small)
        case .failed(let error):
            ContentUnavailableView {
                Label("yaga Can't Use Git", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.description)
            }
        case .ready:
            if let selected = window?.selection, let repository = list.repository(at: selected.repository) {
                detail(repository, selected)
            } else if list.repositories.isEmpty {
                ContentUnavailableView {
                    Label("No Repository Open", systemImage: "folder")
                } description: {
                    Text("Open a repository to see its history.")
                } actions: {
                    Button("Open Repository…", action: open)
                }
            } else {
                ContentUnavailableView(
                    "No Worktree Selected",
                    systemImage: "sidebar.left",
                    description: Text("Choose a worktree in the sidebar to see its history.")
                )
            }
        }
    }

    @ViewBuilder private func detail(_ repository: ListedRepository, _ selected: WorktreeSelection) -> some View {
        switch repository.state {
        case .opening:
            ProgressView()
                .controlSize(.small)
        case .missing:
            ContentUnavailableView {
                Label("Can't Find \(repository.name)", systemImage: "questionmark.folder")
            } description: {
                Text("It was at \(repository.path), and it has been moved or deleted.")
            } actions: {
                Button("Locate…") { locate(repository) }
                Button("Remove from Sidebar") { list.remove(repository) }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Show \(repository.name)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await list.refresh() } }
            }
        case .open(let session):
            if repository.worktrees.contains(where: { $0.path == selected.worktree }) {
                RepositoryView(model: recent.model(for: selected, session: session))
                    .id(selected)
            } else {
                // The worktree is gone, and resolving the selection moves the
                // window to the main worktree.
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var shown: (ListedRepository, Worktree?)? {
        guard let selected = window?.selection, let repository = list.repository(at: selected.repository) else { return nil }
        return (repository, repository.worktrees.first { $0.path == selected.worktree })
    }

    private var title: String { shown?.0.name ?? "yaga" }
    private var subtitle: String { shown?.1?.title ?? "" }

    private func open() {
        openRepository(list: list) { selection.wrappedValue = $0 }
    }

    private func locate(_ repository: ListedRepository) {
        locateRepository(repository, list: list) { selection.wrappedValue = $0 }
    }
}

/// The models of the worktrees a window showed last, so that going back to
/// one shows its history at once rather than loading it again.
final class RecentWorktrees {
    /// How many worktrees to keep. History for Linux takes about 30 MB.
    static let limit = 8

    private var models: [WorktreeSelection: RepositoryModel] = [:]
    /// The selections, from the one shown longest ago to the latest.
    private var order: [WorktreeSelection] = []

    func model(for selection: WorktreeSelection, session: RepositorySession) -> RepositoryModel {
        order.removeAll { $0 == selection }
        order.append(selection)
        // A repository that was removed and added again has a new session.
        if let model = models[selection], model.session === session { return model }
        let model = RepositoryModel(session: session, worktree: selection.worktree)
        models[selection] = model
        while order.count > Self.limit {
            models[order.removeFirst()] = nil
        }
        return model
    }
}
