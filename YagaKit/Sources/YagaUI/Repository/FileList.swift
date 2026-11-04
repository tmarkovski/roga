import GitCore
import IconUI
import SwiftUI

/// The buttons in a panel's header for its list of files: one for filtering,
/// and one for showing the files as a tree, which looks pressed while they are.
/// A filter lists its matches the same way in both layouts, so that button
/// does nothing until the text is gone.
struct FileListCommands: View {
    let list: FileListModel
    let closeFilter: () -> Void
    @AppStorage(FileListSettings.layout) private var layout = FileLayout.list

    var body: some View {
        Button(list.isFilterShown ? "Close the Filter" : "Filter Files", icon: .search) {
            if list.isFilterShown { closeFilter() } else { list.showFilter() }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.icon(isOn: list.isFilterShown))
        .help(list.isFilterShown ? "Close the Filter" : "Filter Files (\(RepositoryCommands.filterFilesShortcut.symbols))")
        Button(toggleTitle, icon: .listTree) {
            layout = layout == .tree ? .list : .tree
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.icon(isOn: layout == .tree))
        .disabled(!list.filter.isEmpty)
        .help(toggleTitle)
    }

    private var toggleTitle: String {
        layout == .tree ? "Show Files as a List" : "Show Files as a Tree"
    }
}

/// The field for filtering a panel's files, which takes the place of the
/// panel's title while it's open.
struct FileFilterField: View {
    @Bindable var list: FileListModel
    /// Moves the keyboard to the rows, and down from the selected one.
    let moveDown: () -> Void
    /// Moves the keyboard to the rows, and selects the first.
    let selectFirstFile: () -> Void
    let close: () -> Void

    var body: some View {
        PanelSearchField(
            prompt: "Filter files",
            label: "Filter Files",
            text: $list.filter,
            wantsFocus: $list.wantsFilterFocus,
            moveDown: moveDown,
            submit: { _ in selectFirstFile() },
            close: close
        )
    }
}

/// What a panel says when its filter leaves no files.
struct NoMatchingFiles: View {
    let filter: String

    var body: some View {
        Text("No files match “\(filter)”")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity)
    }
}

/// The rows of a list of files. Only rows of one height go in the lazy stack,
/// so that it can tell how tall it is without having laid them all out, because
/// a large merge can change thousands of files.
struct FileRows: View {
    let list: FileListModel
    let rows: [FileRow]
    let selectedFile: SelectedFile
    let select: (DiffFile) -> Void
    let toggleFolder: (String) -> Void

    /// The ID of what's at the top of the files, which the rows of a filter
    /// scroll back to.
    static let top = "top of the files"

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                switch row.content {
                case .file(let file):
                    ChangedFileRow(
                        file: file,
                        isSelected: selectedFile.group == row.group && selectedFile.file?.path == file.path,
                        depth: row.depth,
                        showsFolder: list.rowsShowFolders
                    ) {
                        select(file)
                    }
                case .folder(let path, let title, let isCollapsed, let lines):
                    FolderRow(path: path, title: title, isCollapsed: isCollapsed, lines: lines, depth: row.depth) {
                        toggleFolder(path)
                    }
                }
            }
        }
    }
}

extension ScrollViewProxy {
    /// Scrolls to a row of rows that have just changed, which aren't laid out
    /// yet while `onChange` runs, so scrolling then would measure the old ones.
    func scrollOnceLaidOut(to id: some Hashable, anchor: UnitPoint? = nil) {
        Task {
            await Task.yield()
            scrollTo(id, anchor: anchor)
        }
    }
}

/// A row's button: it fills with gray while the pointer is over it, and a little
/// darker while it's selected.
private struct FileRowButton<Content: View>: View {
    var isSelected = false
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Palette.selection : isHovering ? Palette.hover : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovering = $0 }
    }
}

/// How far a row is from the edge, for the folders it's under.
private func indent(_ depth: Int) -> CGFloat {
    CGFloat(depth) * 14
}

/// A folder in the tree of files, in gray like the folders everywhere else. Its
/// triangle comes before its name, unlike the sidebar's, so that the triangles
/// line up with the status letters of the files at the same depth and the rows
/// read as a tree. A closed folder says how many lines change under it.
private struct FolderRow: View {
    let path: String
    let title: String
    let isCollapsed: Bool
    let lines: DiffFile.LineCounts
    let depth: Int
    let toggle: () -> Void

    var body: some View {
        FileRowButton(action: toggle) {
            HStack(spacing: 8) {
                Triangle(pointsDown: !isCollapsed)
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if isCollapsed, lines.added + lines.removed > 0 {
                    LineCounts(added: lines.added, removed: lines.removed)
                        .font(.system(size: 12))
                        .fixedSize()
                }
            }
            .padding(.leading, indent(depth))
        }
        .help(path)
        .accessibilityLabel(path)
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    }
}

/// One file that changed: its status, name and folder, and its line counts.
struct ChangedFileRow: View {
    let file: DiffFile
    let isSelected: Bool
    var depth = 0
    /// Whether to say which folder it's in, which the rows above it say in a
    /// tree.
    var showsFolder = true
    let select: () -> Void

    var body: some View {
        FileRowButton(isSelected: isSelected, action: select) {
            content
                .padding(.leading, indent(depth))
        }
        .help(description)
        .accessibilityLabel(description)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var content: some View {
        HStack(spacing: 8) {
            Text(file.status.letter)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(file.status.color)
                .frame(width: 12)
            Text(file.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(location)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let lines = file.lines {
                if lines.added + lines.removed > 0 {
                    // The name gives way in a narrow panel or a deep folder,
                    // because numbers cut short would say the wrong thing.
                    LineCounts(added: lines.added, removed: lines.removed)
                        .font(.system(size: 12))
                        .fixedSize()
                } else if file.oldMode != file.newMode, file.oldMode != 0, file.newMode != 0 {
                    change("mode")
                }
            } else {
                change("binary")
            }
        }
    }

    private func change(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    /// The file's folder, and where it came from if it moved.
    private var location: String {
        let origin = file.oldPath.map { "from " + $0 }
        return [showsFolder ? String(file.folder) : nil, origin].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var description: String {
        let change = switch file.status {
        case .added: "Added \(file.path)"
        case .deleted: "Deleted \(file.path)"
        case .modified: "Modified \(file.path)"
        case .renamed: "Renamed \(file.oldPath ?? "") to \(file.path)"
        case .copied: "Copied \(file.oldPath ?? "") to \(file.path)"
        case .typeChanged: "Changed the kind of \(file.path)"
        case .untracked: "Untracked \(file.path)"
        case .conflicted: "Conflict in \(file.path)"
        case .other(let letter): "\(letter) \(file.path)"
        }
        guard file.status != .untracked, file.status != .conflicted else { return change }
        guard let lines = file.lines else { return change + ", a binary file" }
        return change + ", \(lines.added) lines added and \(lines.removed) removed"
    }
}

private extension DiffFile.Status {
    /// The color of the status letter. Changed files are orange like the
    /// sidebar's counts, added ones green, and ones that are gone or in conflict
    /// red, like the line counts. Moved and copied ones are blue, because their
    /// contents mostly stayed the same. Untracked ones stay gray, because green
    /// would say they've been added, and git doesn't have them yet. The letter
    /// still says it all without color, which is why `D` and `U` can share one.
    var color: Color {
        switch self {
        case .modified, .typeChanged: .orange
        case .added: .green
        case .deleted, .conflicted: .red
        case .renamed, .copied: .blue
        case .untracked, .other: .secondary
        }
    }
}

/// Lines added in green and removed in red.
struct LineCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(added.formatted())")
                .foregroundStyle(added > 0 ? Color.green : Color.secondary)
            Text("−\(removed.formatted())")
                .foregroundStyle(removed > 0 ? Color.red : Color.secondary)
        }
        .monospacedDigit()
    }
}
