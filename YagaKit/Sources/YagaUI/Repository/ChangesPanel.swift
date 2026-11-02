import GitCore
import RepositoryEngine
import SwiftUI

/// Shows a worktree's uncommitted files, in the place of the commit panel while
/// their row in history is selected. A file with both staged and unstaged
/// changes is listed twice, and each row selects its own diff.
struct ChangesPanel: View {
    let selection: SelectedChanges
    @FocusState private var isFocused: Bool

    var body: some View {
        Panel {
            Text("Uncommitted Changes")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .padding(.leading, 4)
        } trailing: {
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
                    ForEach(SelectedChanges.groups, id: \.self) { group in
                        if !changes[group].isEmpty {
                            GroupOfFiles(group: group, files: changes[group], selectedFile: selection.selectedFile) { file in
                                isFocused = true
                                selection.select(file, in: group)
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
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
                    scroller.scrollTo(FileRowID(group: group, path: path))
                }
            }
        }
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

/// A row's place in the panel, since a file can be in two groups.
private struct FileRowID: Hashable {
    let group: WorktreeChanges.Group
    let path: String
}

/// One group's title, how many files it has and how many lines they change,
/// and its files. Only rows of one height go in the lazy stack, so that it can
/// tell how tall it is without having laid them all out.
private struct GroupOfFiles: View {
    let group: WorktreeChanges.Group
    let files: [DiffFile]
    let selectedFile: SelectedFile
    let select: (DiffFile) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(group.title)
                .fontWeight(.medium)
            Text(files.count, format: .number)
                .foregroundStyle(.secondary)
            let lines = files.compactMap(\.lines)
            if lines.contains(where: { $0.added + $0.removed > 0 }) {
                LineCounts(added: lines.reduce(0) { $0 + $1.added }, removed: lines.reduce(0) { $0 + $1.removed })
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(files.map { (id: FileRowID(group: group, path: $0.path), file: $0) }, id: \.id) { row in
                ChangedFileRow(file: row.file, isSelected: selectedFile.group == group && selectedFile.file?.path == row.file.path) {
                    select(row.file)
                }
            }
        }
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
