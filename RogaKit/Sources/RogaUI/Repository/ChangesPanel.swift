import AppKit
import DiffUI
import GitCore
import IconUI
import RepositoryEngine
import SwiftUI

/// Shows a worktree's uncommitted files, in the place of the commit panel while
/// their row in history is selected, and the message of the next commit. A file
/// with both staged and unstaged changes is listed twice, and each row selects its
/// own diff. Staged files stay in view right above the message (decision 30).
struct ChangesPanel: View {
    let selection: SelectedChanges
    let composer: CommitComposer
    @FocusState private var isFocused: Bool
    /// How much room the lists have, which limits how much of it Staged takes.
    @State private var listsHeight = 0.0

    /// The most of the lists' room that staged files take, once they need it.
    private static let stagedShare = 0.45
    /// How tall a heading is with its padding, and a row, and the end of a list.
    private static let headingHeight = 36.0
    private static let rowHeight = 24.0
    private static let listEnd = 6.0

    private var fileList: FileListModel { selection.fileList }

    var body: some View {
        Panel {
            if fileList.isFilterShown {
                FileFilterField(list: fileList) {
                    isFocused = true
                    selection.selectFile(by: 1)
                } selectFirstFile: {
                    isFocused = true
                    selection.selectFirstFile()
                } close: {
                    closeFilter()
                }
            } else {
                Text("Uncommitted Changes")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
        } trailing: {
            if selection.loaded?.hasSomethingToDiscard == true {
                let canDiscard = selection.canDiscardEverything()
                Button("Discard All Changes", icon: .discard) { selection.askToDiscardEverything() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.icon)
                    .foregroundStyle(Palette.red)
                    .disabled(!canDiscard)
                    .help(canDiscard
                        ? "Discard All Changes… (\(RepositoryCommands.discardAllShortcut.symbols))"
                        : "Finish or abort what's running before discarding everything")
            }
            FileListCommands(list: fileList, closeFilter: closeFilter)
        } content: {
            switch selection.files {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                note(message)
                    .textSelection(.enabled)
            case .loaded(let changes):
                if changes.fileCount == 0 {
                    note("There are no uncommitted changes.")
                } else {
                    VStack(spacing: 0) {
                        list(changes)
                            .onGeometryChange(for: Double.self) { $0.size.height } action: { listsHeight = $0 }
                        CommitBox(composer: composer) { isFocused = true }
                    }
                }
            }
        }
        .onChange(of: selection.focusRequests) { isFocused = true }
    }

    private func list(_ changes: WorktreeChanges) -> some View {
        ScrollViewReader { scroller in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let groups = SelectedChanges.groups.filter { $0 != .staged && !fileList.rows(of: changes[$0], in: $0).isEmpty }
                        if groups.isEmpty, fileList.rows(of: changes.staged, in: .staged).isEmpty {
                            NoMatchingFiles(filter: fileList.filter)
                        }
                        ForEach(groups, id: \.self) { group in
                            groupOfFiles(group, in: changes)
                        }
                    }
                    .padding(.bottom, Self.listEnd)
                    .id(FileRows.top)
                }
                .frame(maxHeight: .infinity)
                let staged = fileList.rows(of: changes.staged, in: .staged)
                if !staged.isEmpty {
                    let needed = Self.headingHeight + Double(staged.count) * Self.rowHeight + Self.listEnd
                    Rectangle()
                        .fill(Palette.separator)
                        .frame(height: 1)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            groupOfFiles(.staged, in: changes)
                        }
                        .padding(.bottom, Self.listEnd)
                    }
                    .frame(height: min(needed, max(listsHeight * Self.stagedShare, Self.headingHeight + 2 * Self.rowHeight)))
                }
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                selection.selectFile(by: press.key == .downArrow ? 1 : -1)
                return .handled
            }
            .onKeyPress(.space, phases: .down) { _ in
                selection.toggleSelectedFile()
                return .handled
            }
            .onChange(of: selection.fileSteps) {
                if let group = selection.selectedFile.group, let path = selection.selectedFile.file?.path {
                    scroller.scrollTo(FileRow.ID(group: group, path: path))
                }
            }
            .onChange(of: fileList.layout) {
                revealSelectedFile(scroller)
            }
            .onChange(of: fileList.filter) {
                if fileList.filter.isEmpty {
                    revealSelectedFile(scroller)
                } else {
                    scroller.scrollOnceLaidOut(to: FileRows.top, anchor: .top)
                }
            }
        }
    }

    private func groupOfFiles(_ group: WorktreeChanges.Group, in changes: WorktreeChanges) -> some View {
        GroupOfFiles(
            group: group,
            files: changes[group],
            list: fileList,
            selectedFile: selection.selectedFile,
            toggleAll: { selection.toggleAll(in: group) },
            discardAll: { selection.askToDiscardAll(in: group) },
            rowAction: FileRowAction(icon: group.stageIcon, title: group.stageTitle, perform: { file in
                selection.toggle(file, in: group)
            }, discard: { file in
                guard let way = group.discarding(file) else { return nil }
                return RowDiscard(icon: way.icon, title: way.fileTitle) {
                    // The next row moves up under the pointer, and that's not what a
                    // double-click meant to take.
                    guard NSApp.currentEvent?.isRepeatedClick != true else { return }
                    selection.discard(file, in: group)
                }
            }),
            folderAction: group == .conflicted ? nil : { path in selection.toggleFolder(path, in: group) },
            folderDiscard: group.folderDiscard.map { way in { path in
                RowDiscard(icon: way.icon, title: way.folderTitle) {
                    guard NSApp.currentEvent?.isRepeatedClick != true else { return }
                    selection.askToDiscardFolder(path, in: group)
                }
            } }
        ) { file in
            isFocused = true
            selection.select(file, in: group)
        } toggleFolder: { path in
            isFocused = true
            fileList.toggleFolder(path, in: group)
        }
    }

    private func closeFilter() {
        fileList.closeFilter()
        isFocused = true
    }

    /// Brings the selected file's row into view, opening its folders, because a
    /// filter can select a file in a closed one.
    private func revealSelectedFile(_ scroller: ScrollViewProxy) {
        guard let group = selection.selectedFile.group, let path = selection.selectedFile.file?.path else { return }
        fileList.reveal(path, in: group)
        scroller.scrollOnceLaidOut(to: FileRow.ID(group: group, path: path))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One group's title, how many files it has and how many lines they change,
/// or as many as a filter left, and its files. While the pointer is over the title,
/// it offers to stage them all or take them all back out.
private struct GroupOfFiles: View {
    let group: WorktreeChanges.Group
    let files: [DiffFile]
    let list: FileListModel
    let selectedFile: SelectedFile
    let toggleAll: () -> Void
    let discardAll: () -> Void
    let rowAction: FileRowAction
    let folderAction: ((String) -> Void)?
    let folderDiscard: ((String) -> RowDiscard)?
    let select: (DiffFile) -> Void
    let toggleFolder: (String) -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            let matching = list.matching(files, in: group)
            Text(group.title)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(matching.count, format: .number)
                .foregroundStyle(.secondary)
            let lines = matching.compactMap(\.lines)
            if lines.contains(where: { $0.added + $0.removed > 0 }) {
                // Numbers cut short would say the wrong thing, so in a narrow panel they
                // go away while the buttons need the room.
                ViewThatFits(in: .horizontal) {
                    LineCounts(added: lines.reduce(0) { $0 + $1.added }, removed: lines.reduce(0) { $0 + $1.removed })
                        .fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            Spacer(minLength: 0)
            if isHovering, group != .conflicted {
                let discardable = matching.filter { group.discarding($0) != nil }.count
                let discardTitle = group.discardAllTitle(matching: discardable, filter: list.filter)
                let stageButton = headingButton(group.stageAllTitle(matching: matching.count, filter: list.filter), help: group.stageAllHelp, action: toggleAll)
                    .fixedSize()
                // It says less in a narrow panel, because two buttons cut short say nothing.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        if discardable > 0 {
                            headingButton(discardTitle, help: group.discardAllHelp, action: discardAll)
                                .foregroundStyle(Palette.red)
                                .fixedSize()
                        }
                        stageButton
                    }
                    HStack(spacing: 4) {
                        if discardable > 0, let way = group.folderDiscard {
                            Button(action: discardAll) {
                                way.icon.image
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
                            .help(discardTitle)
                            .accessibilityLabel(discardTitle)
                        }
                        stageButton
                    }
                }
                .layoutPriority(1)
            }
        }
        .font(.system(size: 12))
        .frame(height: 20)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(.isHeader)
        FileRows(list: list, rows: list.rows(of: files, in: group), selectedFile: selectedFile, select: select, toggleFolder: toggleFolder, rowAction: rowAction, folderAction: folderAction, folderDiscard: folderDiscard)
    }

    private func headingButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .fontWeight(.medium)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Palette.hover)
            }
            .contentShape(Rectangle())
            .help(help)
    }
}

extension WorktreeChanges.Group {
    /// What the panels call the group.
    var title: String {
        switch self {
        case .conflicted: "Conflicts"
        case .unstaged: "Unstaged"
        case .untracked: "Untracked"
        case .staged: "Staged"
        }
    }

    /// What staging or unstaging a file of the group is called. Staging a conflict
    /// tells git it's resolved.
    var stageTitle: String {
        switch self {
        case .conflicted: "Mark Resolved"
        case .unstaged, .untracked: "Stage File"
        case .staged: "Unstage File"
        }
    }

    /// The icon for staging a file, or nil for one that says it in words.
    var stageIcon: Icon? {
        switch self {
        case .conflicted: nil
        case .unstaged, .untracked: .stage
        case .staged: .unstage
        }
    }

    /// The button that stages every file a filter left, or all of them.
    func stageAllTitle(matching count: Int, filter: String) -> String {
        let verb = self == .staged ? "Unstage" : "Stage"
        return filter.isEmpty ? "\(verb) All" : "\(verb) \(count.formatted()) Matching"
    }

    /// How a folder of the group gets discarded, or nil when it can't be.
    var folderDiscard: FileDiscard? {
        switch self {
        case .unstaged: .restore
        case .untracked: .trash
        case .conflicted, .staged: nil
        }
    }

    /// The button that discards every file a filter left, or all of them. It asks
    /// first, which is what the three dots say.
    func discardAllTitle(matching count: Int, filter: String) -> String {
        filter.isEmpty ? "Discard All…" : "Discard \(count.formatted()) Matching…"
    }

    var discardAllHelp: String {
        self == .untracked ? "Move these files to the Trash" : "Throw away the changes to these files, and leave what's staged"
    }

    var stageAllHelp: String {
        switch self {
        case .conflicted: ""
        case .unstaged: "Stage the changes to these files, and leave untracked files alone"
        case .untracked: "Start tracking these files"
        case .staged: "Take these files back out of the next commit, and leave them as they are on disk"
        }
    }
}

extension FileDiscard {
    var icon: Icon {
        switch self {
        case .restore: .discard
        case .trash: .trash
        }
    }

    /// What discarding a file this way is called.
    var fileTitle: String {
        switch self {
        case .restore: "Discard File"
        case .trash: "Move to Trash"
        }
    }

    /// What discarding a folder this way is called. It usually asks first.
    var folderTitle: String {
        switch self {
        case .restore: "Discard Folder…"
        case .trash: "Move Folder to Trash…"
        }
    }
}
