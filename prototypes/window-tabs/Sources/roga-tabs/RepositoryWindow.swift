import AppKit
import SwiftUI

struct RepositoryWindow: View {
    @State private var model: RepositoryModel
    @Environment(\.openWindow) private var openWindow

    init(root: URL) {
        _model = State(initialValue: RepositoryModel(root: root))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model) { tree in
                openWindow(value: RepositoryURL.make(tree.path))
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        } content: {
            CommitListView(model: model)
                .navigationSplitViewColumnWidth(min: 420, ideal: 640)
        } detail: {
            CommitDetailView(model: model)
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
        .background(TabConfigurator(toolTip: RepositoryURL.path(of: model.root), changeSummary: model.changeSummary))
        .task { await model.loadRepository() }
        .onAppear {
            if LaunchOptions.claimOpenAll() {
                for url in LaunchOptions.repositories { openWindow(value: url) }
            }
        }
        .task(id: model.activeWorktree) { await model.loadCommits() }
    }
}

struct SidebarView: View {
    @Bindable var model: RepositoryModel
    let openInNewTab: (Worktree) -> Void
    @State private var showRemotes = false
    @State private var showTags = false

    var body: some View {
        List(selection: $model.activeWorktree) {
            Section("Worktrees") {
                ForEach(model.worktrees) { tree in
                    WorktreeRow(tree: tree, isMain: tree.path == model.worktrees.first?.path)
                        .tag(Optional(tree.path))
                        .contextMenu {
                            Button("Open in New Tab") { openInNewTab(tree) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: tree.path)])
                            }
                        }
                }
            }
            Section("Branches") {
                ForEach(model.refs.branches, id: \.self) { name in
                    Label(name, systemImage: "arrow.triangle.branch")
                }
            }
            if !model.refs.remotes.isEmpty {
                Section("Remotes", isExpanded: $showRemotes) {
                    ForEach(model.refs.remotes, id: \.self) { name in
                        Label(name, systemImage: "network")
                    }
                }
            }
            if !model.refs.tags.isEmpty {
                Section("Tags", isExpanded: $showTags) {
                    ForEach(model.refs.tags, id: \.self) { name in
                        Label(name, systemImage: "tag")
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct WorktreeRow: View {
    let tree: Worktree
    let isMain: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isMain ? "folder.fill" : "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(tree.branchLabel).fontWeight(.medium).lineLimit(1)
                Text(tree.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if tree.changedFiles > 0 {
                Text("\(tree.changedFiles)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                    .help("\(tree.changedFiles) uncommitted changes")
            }
        }
        .padding(.vertical, 2)
    }
}

struct CommitListView: View {
    @Bindable var model: RepositoryModel

    var body: some View {
        // A stand-in for the NSTableView commit list (decision 7).
        Table(model.commits, selection: $model.selectedCommit) {
            TableColumn("Subject") { commit in
                HStack(spacing: 4) {
                    ForEach(commit.refs, id: \.self) { RefBadge(name: $0) }
                    Text(commit.subject).lineLimit(1)
                }
            }
            .width(min: 240, ideal: 420)
            TableColumn("Author", value: \.author)
                .width(min: 80, ideal: 140)
            TableColumn("Date", value: \.date)
                .width(min: 80, ideal: 110)
            TableColumn("Commit") { commit in
                Text(commit.shortHash)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
        }
        .overlay {
            if model.commits.isEmpty && model.isLoading { ProgressView() }
        }
    }
}

struct RefBadge: View {
    let name: String

    var body: some View {
        Text(name.hasPrefix("tag: ") ? String(name.dropFirst(5)) : name)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.2)))
            .foregroundStyle(color)
    }

    private var color: Color {
        if name.hasPrefix("HEAD") { return .green }
        if name.hasPrefix("tag: ") { return .orange }
        if name.contains("/") && !name.hasPrefix("agent/") { return .blue }
        return .accentColor
    }
}

struct CommitDetailView: View {
    let model: RepositoryModel

    var body: some View {
        Group {
            if model.selectedCommit == nil {
                ContentUnavailableView(
                    "No Commit Selected",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Select a commit to see its message and changed files.")
                )
            } else {
                ScrollView([.vertical, .horizontal]) {
                    // A stand-in for the details pane and the TextKit 1 diff view (decision 9).
                    Text(model.detail)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding()
                }
                .defaultScrollAnchor(.topLeading)
            }
        }
        .task(id: model.selectedCommit) { await model.loadDetail() }
    }
}
