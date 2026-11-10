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
    /// What the button on each row does, for a worktree's files. A commit's files
    /// have none, since a commit can't be changed from here.
    var rowAction: FileRowAction?
    /// What the button on a folder's row does, by the folder's path.
    var folderAction: ((String) -> Void)?
    /// The button before that, for throwing away what's in the folder.
    var folderDiscard: ((String) -> RowDiscard)?

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
                        showsFolder: list.rowsShowFolders,
                        action: rowAction
                    ) {
                        select(file)
                    }
                case .folder(let path, let title, let isCollapsed, let lines):
                    FolderRow(path: path, title: title, isCollapsed: isCollapsed, lines: lines, depth: row.depth, action: rowAction, performAction: folderAction, discard: folderDiscard?(path)) {
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

/// What the button on a row of a worktree's files does: staging or unstaging it
/// (decision 30). It shows while the pointer is over the row, in place of the
/// row's line counts, so that nothing moves.
struct FileRowAction {
    /// The icon, or nil for one that says what it does in words.
    let icon: Icon?
    /// What the button says, or its tooltip when it has an icon.
    let title: String
    let perform: (DiffFile) -> Void
    /// The button before it, for throwing the file's changes away, if it has one.
    var discard: ((DiffFile) -> RowDiscard?)?
}

/// The button on a row for throwing away what it's about (decision 39). It comes
/// before the one for staging, so that the one for staging doesn't move, and it's red.
struct RowDiscard {
    let icon: Icon
    let title: String
    let perform: () -> Void
}

/// A row's button: it fills with gray while the pointer is over it, and a little
/// darker while it's selected. The content hears whether the small buttons at the
/// end of the row are covering it.
private struct FileRowButton<Content: View>: View {
    var isSelected = false
    var accessoryIcon: Icon?
    var accessoryTitle: String?
    var accessoryLabel = ""
    var performAccessory: (() -> Void)?
    var discard: RowDiscard?
    var discardLabel = ""
    let action: () -> Void
    @ViewBuilder var content: (_ isShowingAccessory: Bool) -> Content
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                content(isHovering && (performAccessory != nil || discard != nil))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Palette.selection : isHovering ? Palette.hover : .clear)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A double click also selects the row, which is what's wanted anyway.
            .simultaneousGesture(TapGesture(count: 2).onEnded { performAccessory?() })
            if isHovering {
                HStack(spacing: 2) {
                    if let discard {
                        Button(action: discard.perform) {
                            discard.icon.image
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.red)
                                .frame(width: 20, height: 20)
                                .background {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Palette.hover)
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(discard.title)
                        .accessibilityLabel(discardLabel)
                    }
                    if let performAccessory {
                        Button(action: performAccessory) {
                            Group {
                                if let accessoryIcon {
                                    accessoryIcon.image
                                        .font(.system(size: 13))
                                        .frame(width: 20, height: 20)
                                } else {
                                    Text(accessoryTitle ?? "")
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .frame(height: 20)
                                }
                            }
                            .background {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Palette.hover)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(accessoryTitle ?? "")
                        .accessibilityLabel(accessoryLabel)
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, 6)
        .onHover { isHovering = $0 }
    }
}

/// How far a row is from the edge, for the folders it's under.
private func indent(_ depth: Int) -> CGFloat {
    CGFloat(depth) * 14
}

/// The thin lines that run down a row of a tree of files, one under the chevron
/// of each folder it's in. Each row draws its own, and rows have no gap between
/// them, so they join into one line that ends where the folder does. They're
/// under the row's fill, so that they still show on a selected row.
private struct FolderGuides: View {
    let depth: Int

    var body: some View {
        Lines(depth: depth)
            .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            .allowsHitTesting(false)
    }

    private nonisolated struct Lines: Shape {
        let depth: Int

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for folder in 0..<depth {
                // The middle of the column that a folder's chevron is in, 20 points
                // along a row at the top of the tree, and on a half point, so that
                // a line one point wide stays sharp.
                let x = 20.5 + CGFloat(folder) * 14
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            return path
        }
    }
}

/// A folder in the tree of files, in gray like the folders everywhere else. Its
/// chevron comes before its name, unlike the sidebar's, so that the chevrons
/// line up with the status letters of the files at the same depth and the rows
/// read as a tree. A closed folder says how many lines change under it.
struct FolderRow: View {
    let path: String
    let title: String
    let isCollapsed: Bool
    let lines: DiffFile.LineCounts
    let depth: Int
    var action: FileRowAction?
    var performAction: ((String) -> Void)?
    var discard: RowDiscard?
    let toggle: () -> Void

    var body: some View {
        FileRowButton(
            accessoryIcon: action?.icon,
            accessoryTitle: action?.title,
            accessoryLabel: "\(action?.title ?? "") \(path)",
            performAccessory: performAction.map { perform in { perform(path) } },
            discard: discard,
            discardLabel: "\(discard?.title ?? "") \(path)",
            action: toggle
        ) { isShowingAccessory in
            HStack(spacing: 8) {
                Chevron(pointsDown: !isCollapsed)
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
                        .opacity(isShowingAccessory ? 0 : 1)
                }
            }
            .padding(.leading, indent(depth))
        }
        .help(path)
        .accessibilityLabel(path)
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .background { FolderGuides(depth: depth) }
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
    /// What the button at the end of the row does, if it has one.
    var action: FileRowAction?
    let select: () -> Void

    var body: some View {
        let discard = action?.discard?(file)
        FileRowButton(
            isSelected: isSelected,
            accessoryIcon: action?.icon,
            accessoryTitle: action?.title,
            accessoryLabel: "\(action?.title ?? "") \(file.path)",
            performAccessory: action.map { action in { action.perform(file) } },
            discard: discard,
            discardLabel: "\(discard?.title ?? "") \(file.path)",
            action: select
        ) { isShowingAccessory in
            content(hidingCounts: isShowingAccessory, reservingRoom: isShowingAccessory && discard != nil)
                .padding(.leading, indent(depth))
        }
        .help(description)
        .accessibilityLabel(description)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .background { FolderGuides(depth: depth) }
    }

    /// - Parameter reservingRoom: Whether two buttons cover the end of the row, which
    ///   short counts have no room for, so that a long name stops before them.
    private func content(hidingCounts: Bool, reservingRoom: Bool) -> some View {
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
            HStack(spacing: 0) {
                if let lines = file.lines {
                    if lines.added + lines.removed > 0 {
                        // The name gives way in a narrow panel or a deep folder,
                        // because numbers cut short would say the wrong thing.
                        LineCounts(added: lines.added, removed: lines.removed)
                            .font(.system(size: 12))
                            .fixedSize()
                            .opacity(hidingCounts ? 0 : 1)
                    } else if file.oldMode != file.newMode, file.oldMode != 0, file.newMode != 0 {
                        change("mode")
                            .opacity(hidingCounts ? 0 : 1)
                    }
                } else {
                    change("binary")
                        .opacity(hidingCounts ? 0 : 1)
                }
            }
            .frame(minWidth: reservingRoom ? Self.roomForTwoButtons : nil, alignment: .trailing)
        }
    }

    /// How far into a row's content two small buttons reach from its end.
    private static let roomForTwoButtons = 36.0

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
        case .added: Palette.green
        case .deleted, .conflicted: Palette.red
        case .renamed, .copied: Palette.blue
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
                .foregroundStyle(added > 0 ? Palette.green : Color.secondary)
            Text("−\(removed.formatted())")
                .foregroundStyle(removed > 0 ? Palette.red : Color.secondary)
        }
        .monospacedDigit()
    }
}
