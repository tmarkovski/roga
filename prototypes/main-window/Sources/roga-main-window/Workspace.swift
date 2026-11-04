import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The tabs of one window. Each tab shows one repository.
@Observable
final class WorkspaceModel {
    static let sceneID = "workspace"

    var tabs: [RepositoryModel] = []
    var selection: RepositoryModel.ID?
    var showsNavigator = true

    var selected: RepositoryModel? { tabs.first { $0.id == selection } }

    func open(_ root: URL, worktree: String? = nil, select: Bool = true) {
        let path = RepositoryURL.path(of: root)
        if let existing = tabs.first(where: { RepositoryURL.path(of: $0.root) == path }) {
            if select { selection = existing.id }
            return
        }
        let model = RepositoryModel(root: root, worktree: worktree)
        tabs.append(model)
        if select || selection == nil { selection = model.id }
    }

    func chooseAndOpen() {
        RepositoryOpener.choose { [weak self] url in self?.open(url) }
    }

    func close(_ id: RepositoryModel.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selection == id {
            selection = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeOthers(than id: RepositoryModel.ID) {
        tabs.removeAll { $0.id != id }
        selection = id
    }

    /// Command-W closes the selected tab, and the window along with its last tab.
    func closeSelectedTab() {
        if tabs.count <= 1 {
            NSApp.keyWindow?.performClose(nil)
        } else if let selection {
            close(selection)
        }
    }

    func moveToNewWindow(_ id: RepositoryModel.ID, using openWindow: OpenWindowAction) {
        guard let model = tabs.first(where: { $0.id == id }), tabs.count > 1 else { return }
        WorkspaceLauncher.pending.append(PendingTab(root: model.root, worktree: model.activeWorktree))
        close(id)
        openWindow(id: Self.sceneID)
    }

    func select(number: Int) {
        guard !tabs.isEmpty else { return }
        selection = number >= 9 ? tabs.last?.id : tabs[min(number - 1, tabs.count - 1)].id
    }

    func selectAdjacent(_ offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selection }), !tabs.isEmpty else { return }
        selection = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    func move(_ id: RepositoryModel.ID, to target: RepositoryModel.ID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }), from != to else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    /// Each window saves its tabs, so macOS can restore them with the window.
    var savedState: String {
        let lines = tabs.map { "\(RepositoryURL.path(of: $0.root))\t\($0.activeWorktree ?? "")" }
        let selectedIndex = tabs.firstIndex { $0.id == selection } ?? 0
        return (lines + ["selected\t\(selectedIndex)"]).joined(separator: "\n")
    }

    func restore(from state: String) {
        var selectedIndex = 0
        for line in state.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2 else { continue }
            if fields[0] == "selected" {
                selectedIndex = Int(fields[1]) ?? 0
            } else if FileManager.default.fileExists(atPath: fields[0]) {
                open(RepositoryURL.make(fields[0]), worktree: fields[1].isEmpty ? nil : fields[1], select: false)
            }
        }
        if tabs.indices.contains(selectedIndex) { selection = tabs[selectedIndex].id }
    }
}

struct PendingTab {
    let root: URL
    let worktree: String?
}

/// Tabs waiting for the next new window, used by Move Tab to New Window.
enum WorkspaceLauncher {
    static var pending: [PendingTab] = []
}

struct WorkspaceView: View {
    @State private var workspace = WorkspaceModel()
    @SceneStorage("tabs") private var savedTabs = ""

    var body: some View {
        VStack(spacing: 0) {
            TabBar(workspace: workspace)
            Hairline()
            ZStack {
                // Hidden tabs keep their views, so switching back keeps the
                // scroll position and selection. The app will do this with a
                // container view controller instead (see ARCHITECTURE.md).
                ForEach(workspace.tabs) { model in
                    let isSelected = model.id == workspace.selection
                    RepositoryView(model: model, showsNavigator: workspace.showsNavigator) { tree in
                        workspace.open(RepositoryURL.make(tree.path))
                    }
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                }
                if workspace.tabs.isEmpty {
                    EmptyWorkspaceView(workspace: workspace)
                }
            }
        }
        .background(Palette.surface)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowChrome(barHeight: Metrics.tabBarHeight))
        .frame(minWidth: 1000, minHeight: 600)
        .navigationTitle(workspace.selected?.tabTitle ?? "Roga")
        .focusedSceneValue(\.workspace, workspace)
        .onAppear(perform: restore)
        .onChange(of: workspace.savedState) { _, state in savedTabs = state }
    }

    private func restore() {
        guard workspace.tabs.isEmpty else { return }
        if !WorkspaceLauncher.pending.isEmpty {
            for tab in WorkspaceLauncher.pending { workspace.open(tab.root, worktree: tab.worktree) }
            WorkspaceLauncher.pending.removeAll()
        } else if LaunchOptions.claimOpenAll() {
            for url in LaunchOptions.repositories { workspace.open(url, select: false) }
        } else {
            workspace.restore(from: savedTabs)
        }
    }
}

struct TabBar: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.openWindow) private var openWindow
    @State private var dragging: RepositoryModel.ID?

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Metrics.trafficLightsWidth)
            HStack(spacing: 2) {
                ForEach(workspace.tabs) { model in
                    TabItem(
                        model: model,
                        isSelected: model.id == workspace.selection,
                        select: { workspace.selection = model.id },
                        close: { workspace.close(model.id) }
                    )
                    .onDrag {
                        dragging = model.id
                        return NSItemProvider(object: model.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: TabDropDelegate(target: model.id, workspace: workspace, dragging: $dragging))
                    .contextMenu {
                        Button("Close Tab") { workspace.close(model.id) }
                        Button("Close Other Tabs") { workspace.closeOthers(than: model.id) }
                            .disabled(workspace.tabs.count < 2)
                        Button("Move Tab to New Window") { workspace.moveToNewWindow(model.id, using: openWindow) }
                            .disabled(workspace.tabs.count < 2)
                        Divider()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.root]) }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(RepositoryURL.path(of: model.root), forType: .string)
                        }
                    }
                }
                IconButton("plus", help: "New Tab (⌘T)") { workspace.chooseAndOpen() }
            }
            .animation(.snappy(duration: 0.18), value: workspace.tabs.map(\.id))
            Spacer(minLength: 24)
            HStack(spacing: 2) {
                IconButton("magnifyingglass", help: "Search commits (after release 1)") {}
                IconButton("terminal", help: "Git commands Roga ran (coming later)") {}
                IconButton("sidebar.right", help: workspace.showsNavigator ? "Hide Navigator" : "Show Navigator", isOn: workspace.showsNavigator) {
                    workspace.showsNavigator.toggle()
                }
            }
            .padding(.trailing, 10)
        }
        .frame(height: Metrics.tabBarHeight)
        .background(TitleBarDragArea())
        .background(Palette.chrome)
    }
}

struct TabItem: View {
    let model: RepositoryModel
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            RepositoryIcon(name: model.name, hasChanges: model.hasChanges)
            Text(model.tabTitle)
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            CloseButton(action: close)
                .opacity(isSelected || hovering ? 1 : 0)
                .allowsHitTesting(isSelected || hovering)
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Palette.selected : (hovering ? Palette.hover : .clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .help([RepositoryURL.path(of: model.root), model.changeSummary].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.tabTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityAction(named: "Close Tab", close)
    }
}

struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(hovering ? 0.92 : 0.7))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close Tab (⌘W)")
    }
}

/// A colored square with the repository's initial, like a site's icon on a browser tab.
struct RepositoryIcon: View {
    let name: String
    let hasChanges: Bool

    private static let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color.gradient)
            .frame(width: 16, height: 16)
            .overlay {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .topTrailing) {
                if hasChanges {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Palette.chrome, lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                }
            }
    }

    private var color: Color {
        var hash: UInt = 5381
        for scalar in name.unicodeScalars { hash = hash &* 33 &+ UInt(scalar.value) }
        return Self.colors[Int(hash % UInt(Self.colors.count))]
    }
}

struct TabDropDelegate: DropDelegate {
    let target: RepositoryModel.ID
    let workspace: WorkspaceModel
    @Binding var dragging: RepositoryModel.ID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.snappy(duration: 0.18)) { workspace.move(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct EmptyWorkspaceView: View {
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Roga").font(.system(size: 28, weight: .semibold))
                Text("Open a repository to get started.").foregroundStyle(.secondary)
            }
            if !LaunchOptions.repositories.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(LaunchOptions.repositories, id: \.self) { url in
                        RecentRow(url: url) { workspace.open(url) }
                    }
                }
                .frame(width: 420)
            }
            Button("Open Repository…") { workspace.chooseAndOpen() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
    }
}

struct RecentRow: View {
    let url: URL
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                RepositoryIcon(name: url.lastPathComponent, hasChanges: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.system(size: 13, weight: .medium))
                    Text(RepositoryURL.path(of: url)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
