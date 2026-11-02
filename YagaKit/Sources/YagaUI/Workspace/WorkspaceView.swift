import AppKit
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
    @SceneStorage("showsRefsPanel") private var wantsRefsPanel = true
    /// The width of the window, once it's in one.
    @State private var windowWidth: Double?
    /// The width of the sidebar, once it's been laid out.
    @State private var sidebarWidth: Double?

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
                .onGeometryChange(for: Double.self) { $0.size.width } action: { sidebarWidth = $0 }
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
                .inspector(isPresented: refsPanelIsPresented) {
                    refsPanel
                        .inspectorColumnWidth(
                            min: RefsPanelVisibility.defaultWidth,
                            ideal: RefsPanelVisibility.defaultWidth,
                            max: RefsPanelVisibility.maximumWidth
                        )
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        RefsPanelToggle(visibility: refsPanelVisibility)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
        }
        .background {
            WindowWidthReader { windowWidth = $0 }
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
        .focusedSceneValue(\.refsPanelVisibility, refsPanelVisibility)
    }

    /// Whether the panel fits, or nil until the window and the sidebar have
    /// been measured. It stays closed until then, because closing it during the
    /// window's first layout makes AppKit give up on the layout and crash.
    private var refsPanelFits: Bool? {
        guard let windowWidth else { return nil }
        if columns == .detailOnly { return RefsPanelVisibility.fits(window: windowWidth, sidebar: 0) }
        return sidebarWidth.map { RefsPanelVisibility.fits(window: windowWidth, sidebar: $0) }
    }

    private var refsPanelVisibility: RefsPanelVisibility {
        RefsPanelVisibility(isWanted: $wantsRefsPanel, fits: refsPanelFits ?? true)
    }

    /// Whether the panel shows. It only says the user closed it while it fits,
    /// because hiding it for a narrow window doesn't change what they want.
    private var refsPanelIsPresented: Binding<Bool> {
        Binding {
            wantsRefsPanel && refsPanelFits == true
        } set: { isPresented in
            if refsPanelFits == true { wantsRefsPanel = isPresented }
        }
    }

    /// The refs of the repository whose worktree the window shows.
    @ViewBuilder private var refsPanel: some View {
        if let selected = window?.selection,
           let repository = list.repository(at: selected.repository),
           case .open(let session) = repository.state,
           repository.worktrees.contains(where: { $0.path == selected.worktree }) {
            RefsPanel(model: model(for: selected, session: session), isShown: $wantsRefsPanel) { worktree in
                selection.wrappedValue = WorktreeSelection(repository: selected.repository, worktree: worktree)
            }
            .id(selected)
        } else {
            RefsPanelPlaceholder()
        }
    }

    private func model(for selected: WorktreeSelection, session: RepositorySession) -> RepositoryModel {
        recent.model(for: selected, session: session) { [list] count in
            list.setUncommittedFiles(count, in: selected)
        }
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
                RepositoryView(model: model(for: selected, session: session))
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

/// Says how wide the window is, whenever that changes.
///
/// It reads the window rather than the size SwiftUI gives a view, because that
/// size depends on the columns. When they don't fit, it's what they need rather
/// than what the window has, so hiding the refs panel changes it, which would
/// show the panel again, and so on forever.
private struct WindowWidthReader: NSViewRepresentable {
    let changed: (Double) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView()
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.changed = changed
    }

    final class ReaderView: NSView {
        var changed: ((Double) -> Void)?
        private var observation: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation.map(NotificationCenter.default.removeObserver)
            observation = nil
            guard let window else { return }
            observation = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            // SwiftUI is in the middle of an update here.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            if let window { changed?(window.frame.width) }
        }
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

    /// - Parameter reportUncommittedFiles: What a new model calls with how many
    ///   uncommitted files it finds.
    func model(
        for selection: WorktreeSelection,
        session: RepositorySession,
        reportUncommittedFiles: @escaping (Int) -> Void = { _ in }
    ) -> RepositoryModel {
        order.removeAll { $0 == selection }
        order.append(selection)
        // A repository that was removed and added again has a new session.
        if let model = models[selection], model.session === session { return model }
        let model = RepositoryModel(session: session, worktree: selection.worktree, reportUncommittedFiles: reportUncommittedFiles)
        models[selection] = model
        while order.count > Self.limit {
            models[order.removeFirst()] = nil
        }
        return model
    }
}
