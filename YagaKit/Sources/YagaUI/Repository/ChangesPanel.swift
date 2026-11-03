import GitCore
import RepositoryEngine
import SwiftUI

/// Shows a worktree's uncommitted files, in the place of the commit panel while
/// their row in history is selected. A file with both staged and unstaged
/// changes is listed twice, and each row selects its own diff.
struct ChangesPanel: View {
    let selection: SelectedChanges
    @FocusState private var isFocused: Bool

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
                    list(changes)
                }
            }
        }
    }

    private func list(_ changes: WorktreeChanges) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let groups = SelectedChanges.groups.filter { !fileList.rows(of: changes[$0], in: $0).isEmpty }
                    if groups.isEmpty {
                        NoMatchingFiles(filter: fileList.filter)
                    }
                    ForEach(groups, id: \.self) { group in
                        GroupOfFiles(group: group, files: changes[group], list: fileList, selectedFile: selection.selectedFile) { file in
                            isFocused = true
                            selection.select(file, in: group)
                        } toggleFolder: { path in
                            isFocused = true
                            fileList.toggleFolder(path, in: group)
                        }
                    }
                }
                .padding(.bottom, 6)
                .id(FileRows.top)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                selection.selectFile(by: press.key == .downArrow ? 1 : -1)
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
/// or as many as a filter left, and its files.
private struct GroupOfFiles: View {
    let group: WorktreeChanges.Group
    let files: [DiffFile]
    let list: FileListModel
    let selectedFile: SelectedFile
    let select: (DiffFile) -> Void
    let toggleFolder: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            let matching = list.matching(files, in: group)
            Text(group.title)
                .fontWeight(.medium)
            Text(matching.count, format: .number)
                .foregroundStyle(.secondary)
            let lines = matching.compactMap(\.lines)
            if lines.contains(where: { $0.added + $0.removed > 0 }) {
                LineCounts(added: lines.reduce(0) { $0 + $1.added }, removed: lines.reduce(0) { $0 + $1.removed })
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
        FileRows(list: list, rows: list.rows(of: files, in: group), selectedFile: selectedFile, select: select, toggleFolder: toggleFolder)
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
}
