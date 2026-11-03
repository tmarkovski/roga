import GitCore
import SwiftUI

/// Shows the commit selected in history: its message, who wrote it and when,
/// its parents, and the files it changed.
struct CommitPanel: View {
    let model: RepositoryModel
    @FocusState private var isFocused: Bool

    private var commit: SelectedCommit { model.selectedCommit }
    private var fileList: FileListModel { commit.fileList }

    var body: some View {
        Panel {
            if fileList.isFilterShown {
                FileFilterField(list: fileList) {
                    isFocused = true
                    commit.selectFile(by: 1)
                } selectFirstFile: {
                    isFocused = true
                    commit.selectFirstFile()
                } close: {
                    closeFilter()
                }
            } else {
                // The hash gives way first in a narrow panel, because the button
                // still copies it.
                ViewThatFits(in: .horizontal) {
                    title(showingHash: true)
                    title(showingHash: false)
                }
            }
        } trailing: {
            FileListCommands(list: fileList, closeFilter: closeFilter)
                .disabled(commit.id == nil)
        } content: {
            if commit.id == nil {
                note("Select a commit to see what it changed.")
            } else if let problem = commit.problem {
                note(problem)
            } else if let info = commit.info {
                ScrollViewReader { scroller in
                    ScrollView {
                        CommitDetails(info: info, files: commit.files, model: model) { file in
                            isFocused = true
                            commit.select(file)
                        } toggleFolder: { path in
                            isFocused = true
                            fileList.toggleFolder(path)
                        }
                    }
                    // Each commit starts at the top of its message.
                    .id(info.id)
                    .focusable()
                    .focused($isFocused)
                    .focusEffectDisabled()
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        commit.selectFile(by: press.key == .downArrow ? 1 : -1)
                        return .handled
                    }
                    .onChange(of: commit.fileSteps) {
                        if let path = commit.selectedFile.file?.path { scroller.scrollTo(FileRow.ID(path: path)) }
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
        }
    }

    private func title(showingHash: Bool) -> some View {
        HStack(spacing: 4) {
            Text("Commit")
                .font(.system(size: 13, weight: .medium))
                .padding(.leading, 4)
            if let id = commit.id {
                if showingHash {
                    Text(id.hex.prefix(8))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                Button("Copy Commit Hash", systemImage: "doc.on.doc") {
                    commit.copyHash()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.icon)
                .help("Copy Commit Hash (\(RepositoryCommands.copyHashShortcut.symbols))")
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
        guard let path = commit.selectedFile.file?.path else { return }
        fileList.reveal(path)
        scroller.scrollOnceLaidOut(to: FileRow.ID(path: path))
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

/// A commit's message, its author, committer and parents, and its files.
private struct CommitDetails: View {
    let info: CommitInfo
    let files: SelectedCommit.Files
    let model: RepositoryModel
    let select: (DiffFile) -> Void
    let toggleFolder: (String) -> Void
    /// It's one setting for every commit, so that moving through history with a
    /// long message out of the way keeps it out of the way.
    @AppStorage("collapsesCommitBody") private var collapsesBody = false

    private var fileList: FileListModel { model.selectedCommit.fileList }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A filter's matches go at the top, because a long message could
            // otherwise leave them out of sight.
            if fileList.filter.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    message
                    people
                    parents
                }
                .font(.system(size: 13))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1)
            }
            switch files {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .padding(14)
                    .frame(maxWidth: .infinity)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(14)
            case .loaded(let files):
                let rows = fileList.rows(of: files)
                if rows.isEmpty, !fileList.filter.isEmpty {
                    NoMatchingFiles(filter: fileList.filter)
                } else {
                    FilesSummary(files: fileList.matching(files), total: files.count, isMerge: info.parents.count > 1)
                        .id(FileRows.top)
                }
                FileRows(list: fileList, rows: rows, selectedFile: model.selectedCommit.selectedFile, select: select, toggleFolder: toggleFolder)
                    .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder private var message: some View {
        if info.subject.isEmpty {
            Text("This commit has no message.")
                .foregroundStyle(.secondary)
        } else if info.body.isEmpty {
            Text(info.subject)
                .fontWeight(.semibold)
                .textSelection(.enabled)
        } else {
            CollapsibleSubject(subject: info.subject, isCollapsed: $collapsesBody)
            if !collapsesBody {
                Text(info.body)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var people: some View {
        VStack(alignment: .leading, spacing: 2) {
            signature(info.author, title: "Author")
            if info.committer != info.author {
                signature(info.committer, title: "Committer")
            }
        }
    }

    private func signature(_ signature: Signature, title: String) -> some View {
        let date = Date(timeIntervalSince1970: TimeInterval(signature.time))
        let label = Text(title).foregroundStyle(.secondary)
        let email = signature.email.isEmpty ? "" : " <\(signature.email)>"
        let details = Text("\(email)  \(date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
        return Text("\(label)  \(signature.name)\(details)")
            .font(.system(size: 12))
            .textSelection(.enabled)
    }

    @ViewBuilder private var parents: some View {
        if !info.parents.isEmpty {
            HStack(spacing: 8) {
                Text(info.parents.count == 1 ? "Parent" : "Parents")
                    .foregroundStyle(.secondary)
                ForEach(info.parents, id: \.self) { parent in
                    ParentLink(id: parent, isInHistory: model.hasCommit(parent)) {
                        model.select(commit: parent)
                    }
                }
            }
            .font(.system(size: 12))
        }
    }
}

/// The subject of a commit that has more to its message, which hides and shows
/// the rest. Clicking the subject does the same as the triangle after it, so
/// it's underlined while the pointer is over it. It can't be selected, because
/// selectable text shows the text cursor, which says the click would do nothing.
private struct CollapsibleSubject: View {
    let subject: String
    @Binding var isCollapsed: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            Button {
                isCollapsed.toggle()
            } label: {
                Text(subject)
                    .fontWeight(.semibold)
                    .underline(isHovering)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            Button {
                isCollapsed.toggle()
            } label: {
                Triangle(pointsDown: !isCollapsed)
            }
            .buttonStyle(.icon(size: 18))
            .offset(y: -1)
            .help(title)
            .accessibilityLabel(title)
        }
    }

    private var title: String {
        isCollapsed ? "Show Commit Message" : "Hide Commit Message"
    }
}

/// A parent's short hash, which selects the parent in history.
private struct ParentLink: View {
    let id: ObjectID
    let isInHistory: Bool
    let select: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            Text(id.hex.prefix(8))
                .font(.system(size: 12, design: .monospaced))
                .underline(isHovering && isInHistory)
        }
        .buttonStyle(.plain)
        .disabled(!isInHistory)
        .onHover { isHovering = $0 }
        .pointerStyle(isInHistory ? .link : nil)
        .help(isInHistory ? "Select the parent in history" : "History doesn't have this commit")
    }
}

/// How many files a commit changed, and how many lines, or how many of them a
/// filter left.
private struct FilesSummary: View {
    let files: [DiffFile]
    /// How many files the commit changed.
    let total: Int
    let isMerge: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            if !files.isEmpty {
                LineCounts(added: files.reduce(0) { $0 + ($1.lines?.added ?? 0) }, removed: files.reduce(0) { $0 + ($1.lines?.removed ?? 0) })
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var title: String {
        let count = if files.count < total {
            "\(files.count.formatted()) of \(total.formatted()) files"
        } else if files.isEmpty {
            "No files changed"
        } else {
            files.count == 1 ? "1 file changed" : "\(files.count.formatted()) files changed"
        }
        return isMerge ? count + " compared with the first parent" : count
    }
}
