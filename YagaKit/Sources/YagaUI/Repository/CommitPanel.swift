import GitCore
import SwiftUI

/// Shows the commit selected in history: its message, who wrote it and when,
/// its parents, and the files it changed.
struct CommitPanel: View {
    let model: RepositoryModel
    @FocusState private var isFocused: Bool

    private var commit: SelectedCommit { model.selectedCommit }

    var body: some View {
        Panel {
            Text("Commit")
                .font(.system(size: 13, weight: .medium))
                .padding(.leading, 4)
            if let id = commit.id {
                Text(id.hex.prefix(8))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                Button("Copy Commit Hash", systemImage: "doc.on.doc") {
                    commit.copyHash()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.icon)
                .help("Copy Commit Hash (\(RepositoryCommands.copyHashShortcut.symbols))")
            }
        } trailing: {
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
                        if let path = commit.selectedFile.file?.path { scroller.scrollTo(path) }
                    }
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

/// A commit's message, its author, committer and parents, and its files.
private struct CommitDetails: View {
    let info: CommitInfo
    let files: SelectedCommit.Files
    let model: RepositoryModel
    let select: (DiffFile) -> Void
    /// It's one setting for every commit, so that moving through history with a
    /// long message out of the way keeps it out of the way.
    @AppStorage("collapsesCommitBody") private var collapsesBody = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                FilesSummary(files: files, isMerge: info.parents.count > 1)
                // A large merge can change thousands of files. Only rows of one
                // height go in the lazy stack, so that it can tell how tall it
                // is without having laid them all out.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files, id: \.path) { file in
                        ChangedFileRow(file: file, isSelected: model.selectedCommit.selectedFile.file?.path == file.path) {
                            select(file)
                        }
                    }
                }
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

/// How many files a commit changed, and how many lines.
private struct FilesSummary: View {
    let files: [DiffFile]
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
        let count = files.isEmpty ? "No files changed" : files.count == 1 ? "1 file changed" : "\(files.count.formatted()) files changed"
        return isMerge ? count + " compared with the first parent" : count
    }
}

/// One file that changed: its status, name and folder, and its line counts. It
/// fills with gray while the pointer is over it, and a little darker while it's
/// selected.
struct ChangedFileRow: View {
    let file: DiffFile
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
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
        .help(description)
        .accessibilityLabel(description)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var content: some View {
        HStack(spacing: 8) {
            Text(file.status.letter)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
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
                    LineCounts(added: lines.added, removed: lines.removed)
                        .font(.system(size: 12))
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
        return [String(file.folder), origin].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
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
