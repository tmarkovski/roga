import AppKit
import SwiftUI

/// The content of one tab. History sits on top, the selected commit and its
/// diff below, and the navigator on the right. Every section is a panel with
/// its own header.
struct RepositoryView: View {
    let model: RepositoryModel
    let showsNavigator: Bool
    let openWorktreeInNewTab: (Worktree) -> Void

    var body: some View {
        HSplitView {
            VSplitView {
                HistoryPanel(model: model)
                    .frame(minHeight: 180, idealHeight: 360)
                lowerPanels
                    .frame(minHeight: 220, idealHeight: 480)
            }
            .frame(minWidth: 640, maxWidth: .infinity)
            if showsNavigator {
                NavigatorPanel(model: model, openInNewTab: openWorktreeInNewTab)
                    .frame(minWidth: 220, idealWidth: 290, maxWidth: 420)
            }
        }
        .task { await model.loadRepository() }
        .task(id: model.activeWorktree) { await model.loadWorktree() }
        .task(id: model.selectedCommit) { await model.loadDetails() }
        .task(id: model.diffKey) { await model.loadDiff() }
    }

    @ViewBuilder private var lowerPanels: some View {
        switch model.mode {
        case .history:
            HSplitView {
                CommitPanel(model: model)
                    .frame(minWidth: 240, idealWidth: 330, maxWidth: 560)
                DiffPanel(model: model)
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
        case .changes:
            DiffPanel(model: model)
        }
    }
}

struct HistoryPanel: View {
    @Bindable var model: RepositoryModel

    var body: some View {
        Panel {
            SubTab(title: "History", isSelected: model.mode == .history) { model.mode = .history }
            SubTab(title: "Changes", count: model.changes.count, isSelected: model.mode == .changes) { model.mode = .changes }
        } trailing: {
            if let active = model.active {
                Label(active.branchLabel, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.trailing, 6)
            }
            IconButton("line.3.horizontal.decrease", help: "Choose Branches to Show") {}
            IconButton("ellipsis", help: "More") {}
        } content: {
            switch model.mode {
            case .history: CommitList(model: model)
            case .changes: ChangeList(model: model)
            }
        }
    }
}

struct CommitList: View {
    @Bindable var model: RepositoryModel
    @FocusState private var focused: Bool

    var body: some View {
        let remotes = Set(model.refs.remotes.compactMap { $0.split(separator: "/").first.map(String.init) })
        ScrollViewReader { proxy in
            ScrollView {
                // A stand-in for the NSTableView commit list (decision 7).
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.commits.enumerated()), id: \.element.id) { index, commit in
                        CommitRow(
                            commit: commit,
                            remotes: remotes,
                            isFirst: index == 0,
                            isLast: index == model.commits.count - 1,
                            isSelected: commit.id == model.selectedCommit
                        )
                        .id(commit.id)
                        .onActivate {
                            model.selectedCommit = commit.id
                            focused = true
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if model.commits.isEmpty && model.isLoadingHistory { ProgressView().controlSize(.small) }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
        }
    }

    private func move(_ offset: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        model.selectAdjacentCommit(offset)
        if let id = model.selectedCommit { proxy.scrollTo(id) }
        return .handled
    }
}

struct CommitRow: View {
    let commit: Commit
    let remotes: Set<String>
    let isFirst: Bool
    let isLast: Bool
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            GraphCell(isFirst: isFirst, isLast: isLast, isMerge: commit.parentCount > 1)
                .frame(width: 16)
            HStack(spacing: 5) {
                ForEach(commit.refs, id: \.self) { RefBadge(name: $0, remotes: remotes) }
                Text(commit.subject).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(commit.author)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
            Text(commit.date)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)
            Text(commit.shortHash)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Palette.selected : (hovering ? Palette.hover : .clear))
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A placeholder for the graph: one straight line. The real lanes come from
/// the commit-graph reader.
struct GraphCell: View {
    let isFirst: Bool
    let isLast: Bool
    let isMerge: Bool

    var body: some View {
        Canvas { context, size in
            let x = size.width / 2
            let y = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: x, y: isFirst ? y : 0))
            line.addLine(to: CGPoint(x: x, y: isLast ? y : size.height))
            context.stroke(line, with: .color(.accentColor.opacity(0.6)), lineWidth: 2)
            let radius: CGFloat = isMerge ? 4.5 : 4
            let dot = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(isMerge ? Palette.surface : .accentColor))
            if isMerge { context.stroke(dot, with: .color(.accentColor), lineWidth: 2) }
        }
    }
}

struct RefBadge: View {
    let name: String
    let remotes: Set<String>

    var body: some View {
        HStack(spacing: 3) {
            if isHead { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
            if isTag { Image(systemName: "tag").font(.system(size: 8.5)) }
            Text(label)
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.14)))
        .foregroundStyle(color)
    }

    private var isHead: Bool { name.hasPrefix("HEAD -> ") || name == "HEAD" }
    private var isTag: Bool { name.hasPrefix("tag: ") }
    private var isRemote: Bool { name.split(separator: "/").first.map { remotes.contains(String($0)) } ?? false }

    private var label: String {
        if name.hasPrefix("HEAD -> ") { return String(name.dropFirst("HEAD -> ".count)) }
        if isTag { return String(name.dropFirst("tag: ".count)) }
        return name
    }

    private var color: Color {
        if isHead { return .green }
        if isTag { return .orange }
        if isRemote { return .purple }
        return .blue
    }
}

struct ChangeList: View {
    @Bindable var model: RepositoryModel
    @FocusState private var focused: Bool

    var body: some View {
        if model.changes.isEmpty {
            ContentUnavailableView(
                "No Uncommitted Changes",
                systemImage: "checkmark.circle",
                description: Text("This worktree matches its last commit.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.changes) { entry in
                        ChangeRow(entry: entry, isSelected: entry.id == model.selectedChange)
                            .onActivate {
                                model.selectedChange = entry.id
                                focused = true
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) {
                model.selectAdjacentChange(1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                model.selectAdjacentChange(-1)
                return .handled
            }
        }
    }
}

struct ChangeRow: View {
    let entry: StatusEntry
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(letter: entry.letter)
            FileName(path: entry.path)
            Spacer(minLength: 8)
            Text(description).font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Palette.selected : (hovering ? Palette.hover : .clear))
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var description: String {
        switch entry.letter {
        case "U": "Untracked"
        case "A": "Added"
        case "D": "Deleted"
        case "R": "Renamed"
        default: "Modified"
        }
    }
}

struct StatusBadge: View {
    let letter: String

    var body: some View {
        Text(letter)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch letter {
        case "A", "U": .green
        case "D": .red
        case "R": .blue
        default: .orange
        }
    }
}

struct FileName: View {
    let path: String

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            Text(name).lineLimit(1)
            if !folder.isEmpty {
                Text(folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
        }
    }
}

struct CommitPanel: View {
    @Bindable var model: RepositoryModel

    var body: some View {
        Panel {
            PanelTitle(text: model.details.map { "Commit \($0.hash.prefix(8))" } ?? "Commit")
        } trailing: {
            IconButton("doc.on.doc", help: "Copy Commit Hash") {
                guard let hash = model.details?.hash else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hash, forType: .string)
            }
            IconButton("ellipsis", help: "More") {}
        } content: {
            if let details = model.details {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        CommitSummary(details: details)
                            .padding(.bottom, 14)
                        FilesHeader(files: model.files)
                        ForEach(model.files) { file in
                            FileRow(file: file, isSelected: file.id == model.selectedFile)
                                .onActivate { model.selectedFile = file.id }
                        }
                    }
                    .padding(12)
                }
            } else {
                Color.clear
            }
        }
    }
}

struct CommitSummary: View {
    let details: CommitDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(details.subject)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !details.body.isEmpty {
                Text(details.body)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Author").foregroundStyle(.secondary)
                    Text("\(details.author) <\(details.email)>").lineLimit(1)
                }
                GridRow {
                    Text("Date").foregroundStyle(.secondary)
                    Text(details.date)
                }
                GridRow {
                    Text(details.parents.count > 1 ? "Parents" : "Parent").foregroundStyle(.secondary)
                    Text(details.parents.map { String($0.prefix(8)) }.joined(separator: ", "))
                        .font(.system(size: 11.5, design: .monospaced))
                }
            }
            .font(.system(size: 12))
        }
    }
}

struct FilesHeader: View {
    let files: [ChangedFile]

    var body: some View {
        HStack(spacing: 8) {
            Text(files.count == 1 ? "1 file changed" : "\(files.count) files changed")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text("+\(files.reduce(0) { $0 + ($1.added ?? 0) })").foregroundStyle(.green)
            Text("−\(files.reduce(0) { $0 + ($1.deleted ?? 0) })").foregroundStyle(.red)
        }
        .font(.system(size: 11.5).monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

struct FileRow: View {
    let file: ChangedFile
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            FileName(path: file.path)
            Spacer(minLength: 6)
            if let added = file.added, let deleted = file.deleted {
                Text("+\(added)").foregroundStyle(.green)
                Text("−\(deleted)").foregroundStyle(.red)
            } else {
                Text("binary").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12.5))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Palette.selected : (hovering ? Palette.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct DiffPanel: View {
    let model: RepositoryModel

    var body: some View {
        Panel {
            PathBreadcrumb(path: currentPath ?? "")
        } trailing: {
            IconButton("text.magnifyingglass", help: "Find in Diff") {}
            IconButton("arrow.up.forward.app", help: "Open in Editor") {}
            IconButton("ellipsis", help: "More") {}
        } content: {
            if model.diff.isEmpty {
                Text(currentPath == nil ? "Select a file to see its changes." : "No changes to show.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A stand-in for the TextKit 1 diff view (decision 9).
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.diff) { DiffLineView(line: $0) }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var currentPath: String? {
        switch model.mode {
        case .history: model.files.first { $0.id == model.selectedFile }?.diffPath
        case .changes: model.selectedChange
        }
    }
}

/// Shows a path the way the Claude app does: folders in gray, the file name in full color.
struct PathBreadcrumb: View {
    let path: String

    var body: some View {
        Text(attributed)
            .font(.system(size: 12.5))
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.leading, 4)
    }

    private var attributed: AttributedString {
        let parts = path.split(separator: "/").map(String.init)
        var result = AttributedString()
        for (index, part) in parts.enumerated() {
            var piece = AttributedString(part)
            if index < parts.count - 1 {
                piece.foregroundColor = .secondary
                var separator = AttributedString(" / ")
                separator.foregroundColor = .secondary
                piece.append(separator)
            }
            result.append(piece)
        }
        return result
    }
}

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            .background(background)
    }

    private var foreground: Color {
        switch line.kind {
        case .header, .hunk: .secondary
        default: .primary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Palette.added
        case .removed: Palette.removed
        case .hunk: Palette.hunk
        default: .clear
        }
    }
}
