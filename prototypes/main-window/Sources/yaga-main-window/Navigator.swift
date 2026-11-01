import AppKit
import SwiftUI

/// The panel on the right that lists a repository's worktrees, branches,
/// remotes, tags and stashes, like the file tree in the Claude app.
struct NavigatorPanel: View {
    @Bindable var model: RepositoryModel
    let openInNewTab: (Worktree) -> Void
    @State private var filter = ""
    @State private var collapsed: Set<String> = ["Remotes", "Tags"]

    var body: some View {
        Panel {
            FilterField(text: $filter, prompt: "Filter worktrees, branches and tags")
        } trailing: {
            EmptyView()
        } content: {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    NavSection(title: "Worktrees", count: worktrees.count, isExpanded: expanded("Worktrees")) {
                        ForEach(worktrees) { tree in
                            WorktreeRow(
                                tree: tree,
                                isMain: tree.path == model.mainWorktree?.path,
                                isActive: tree.path == model.activeWorktree
                            )
                            .onActivate { model.activeWorktree = tree.path }
                            .contextMenu {
                                Button("Open in New Tab") { openInNewTab(tree) }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: tree.path)])
                                }
                                Button("Copy Path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(tree.path, forType: .string)
                                }
                            }
                        }
                    }
                    NavSection(title: "Branches", count: branches.count, isExpanded: expanded("Branches")) {
                        ForEach(branches, id: \.self) { name in
                            NavRow(systemImage: "arrow.triangle.branch", title: name, isCurrent: name == model.active?.branch)
                        }
                    }
                    NavSection(title: "Remotes", count: remotes.count, isExpanded: expanded("Remotes")) {
                        ForEach(remotes, id: \.self) { name in
                            NavRow(systemImage: "network", title: name)
                        }
                    }
                    NavSection(title: "Tags", count: tags.count, isExpanded: expanded("Tags")) {
                        ForEach(tags, id: \.self) { name in
                            NavRow(systemImage: "tag", title: name)
                        }
                    }
                    NavSection(title: "Stashes", count: stashes.count, isExpanded: expanded("Stashes")) {
                        if stashes.isEmpty {
                            Text("No stashes")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 28)
                                .frame(height: 24)
                        }
                        ForEach(stashes) { stash in
                            NavRow(systemImage: "tray", title: stash.message, detail: stash.id)
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    private func matches(_ text: String) -> Bool {
        filter.isEmpty || text.localizedCaseInsensitiveContains(filter)
    }

    private var worktrees: [Worktree] { model.worktrees.filter { matches($0.branchLabel) || matches($0.name) } }
    private var branches: [String] { model.refs.branches.filter(matches) }
    private var remotes: [String] { model.refs.remotes.filter(matches) }
    private var tags: [String] { model.refs.tags.filter(matches) }
    private var stashes: [Stash] { model.refs.stashes.filter { matches($0.message) } }

    /// Every section opens while filtering, so matches are never hidden.
    private func expanded(_ title: String) -> Binding<Bool> {
        Binding(
            get: { !filter.isEmpty || !collapsed.contains(title) },
            set: { isExpanded in
                if isExpanded { collapsed.remove(title) } else { collapsed.insert(title) }
            }
        )
    }
}

struct FilterField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.field))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.separator))
        .frame(maxWidth: .infinity)
    }
}

struct NavSection<Content: View>: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    Text(title).font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Text("\(count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            if isExpanded { content }
        }
        .padding(.bottom, 4)
    }
}

struct WorktreeRow: View {
    let tree: Worktree
    let isMain: Bool
    let isActive: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isMain ? "folder.fill" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(tree.branchLabel)
                    .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                    .lineLimit(1)
                Text(tree.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if tree.changedFiles > 0 {
                Text("\(tree.changedFiles)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .help("\(tree.changedFiles) uncommitted changes")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? Palette.selected : (hovering ? Palette.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct NavRow: View {
    let systemImage: String
    let title: String
    var detail: String?
    var isCurrent = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12.5, weight: isCurrent ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
