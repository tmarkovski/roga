import AppKit
import SwiftUI

/// The panel on the right that lists a repository's worktrees, branches,
/// remotes, tags and stashes. It's a shade darker than the other panels, like
/// the Claude app's sidebar. Rows show a count or status at rest and their
/// commands when the pointer is over them.
struct NavigatorPanel: View {
    @Bindable var model: RepositoryModel
    let openInNewTab: (Worktree) -> Void
    @State private var filter = ""
    @State private var collapsed: Set<String> = ["Remotes", "Tags"]

    var body: some View {
        Panel(background: Palette.sidebar, showsHeaderDivider: false) {
            FilterField(text: $filter, prompt: "Filter worktrees, branches and tags")
        } trailing: {
            EmptyView()
        } content: {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    NavSection(title: "Worktrees", count: worktrees.count, isExpanded: expanded("Worktrees"), commands: [
                        NavCommand(systemImage: "plus.rectangle.on.rectangle", help: "Open Every Worktree in a Tab") {
                            for tree in model.worktrees.dropFirst() { openInNewTab(tree) }
                        },
                        NavCommand(systemImage: "plus", help: "New Worktree (release 2)") {},
                    ]) {
                        ForEach(worktrees) { tree in
                            WorktreeRow(
                                tree: tree,
                                isMain: tree.path == model.mainWorktree?.path,
                                isActive: tree.path == model.activeWorktree,
                                openInNewTab: { openInNewTab(tree) }
                            )
                            .onActivate { model.activeWorktree = tree.path }
                            .contextMenu {
                                Button("Open in New Tab") { openInNewTab(tree) }
                                Button("Open in Terminal") { Terminal.open(tree.path) }
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
                    NavSection(title: "Branches", count: branches.count, isExpanded: expanded("Branches"), commands: [
                        NavCommand(systemImage: "line.3.horizontal.decrease", help: "Sort and Filter Branches") {},
                        NavCommand(systemImage: "plus", help: "New Branch (release 2)") {},
                    ]) {
                        ForEach(branches, id: \.self) { name in
                            NavRow(systemImage: "arrow.triangle.branch", title: name, isCurrent: name == model.active?.branch)
                        }
                    }
                    NavSection(title: "Remotes", count: remotes.count, isExpanded: expanded("Remotes"), commands: [
                        NavCommand(systemImage: "line.3.horizontal.decrease", help: "Sort and Filter Remote Branches") {},
                        NavCommand(systemImage: "arrow.down.circle", help: "Fetch (release 2)") {},
                    ]) {
                        ForEach(remotes, id: \.self) { name in
                            NavRow(systemImage: "network", title: name)
                        }
                    }
                    NavSection(title: "Tags", count: tags.count, isExpanded: expanded("Tags"), commands: [
                        NavCommand(systemImage: "line.3.horizontal.decrease", help: "Sort and Filter Tags") {},
                        NavCommand(systemImage: "plus", help: "New Tag (release 2)") {},
                    ]) {
                        ForEach(tags, id: \.self) { name in
                            NavRow(systemImage: "tag", title: name)
                        }
                    }
                    NavSection(title: "Stashes", count: stashes.count, isExpanded: expanded("Stashes"), commands: [
                        NavCommand(systemImage: "plus", help: "Stash Changes (release 2)") {},
                    ]) {
                        if stashes.isEmpty {
                            Text("No stashes")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 10)
                                .frame(height: 24)
                        }
                        ForEach(stashes) { stash in
                            NavRow(systemImage: "tray", title: stash.message, detail: stash.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
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

struct NavCommand {
    let systemImage: String
    let help: String
    let action: () -> Void
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

/// A section header in the Claude app's style: the title with a small
/// triangle after it, the count at rest, and the section's commands on hover.
struct NavSection<Content: View>: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    var commands: [NavCommand] = []
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                Spacer(minLength: 8)
                ZStack(alignment: .trailing) {
                    Text("\(count)")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 6)
                        .opacity(hovering ? 0 : 1)
                    HStack(spacing: 2) {
                        ForEach(commands.indices, id: \.self) { index in
                            let command = commands[index]
                            IconButton(command.systemImage, help: command.help, size: 24, action: command.action)
                        }
                    }
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Palette.sidebarHover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                withAnimation(.snappy(duration: 0.15)) { isExpanded.toggle() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(title), \(count)")
            .accessibilityAddTraits(.isHeader)
            .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") { isExpanded.toggle() }
            if isExpanded { content }
        }
        .padding(.top, 4)
    }
}

struct WorktreeRow: View {
    let tree: Worktree
    let isMain: Bool
    let isActive: Bool
    let openInNewTab: () -> Void
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
            ZStack(alignment: .trailing) {
                if tree.changedFiles > 0 {
                    Text("\(tree.changedFiles)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                        .padding(.trailing, 4)
                        .opacity(hovering ? 0 : 1)
                }
                HStack(spacing: 2) {
                    IconButton("plus.rectangle.on.rectangle", help: "Open in New Tab", size: 24, action: openInNewTab)
                    IconButton("terminal", help: "Open in Terminal", size: 24) { Terminal.open(tree.path) }
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Palette.sidebarSelected : (hovering ? Palette.sidebarHover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tree.changedFiles > 0 ? "\(tree.changedFiles) uncommitted changes" : "")
        .accessibilityAction(named: "Open in New Tab", openInNewTab)
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
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Palette.sidebarHover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

enum Terminal {
    static func open(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(filePath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
