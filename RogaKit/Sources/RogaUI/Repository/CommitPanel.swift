import GitCore
import IconUI
import SwiftUI

/// Shows what's selected in history or the refs panel (decision 56): a commit, with
/// its message, who wrote it and when, its parents and the files it changed;
/// several commits as one diff; a branch since it left the main branch; or what a
/// stash holds.
struct CommitPanel: View {
    let model: RepositoryModel
    @FocusState private var isFocused: Bool

    private var commit: SelectedCommit { model.selectedCommit }
    private var fileList: FileListModel { commit.fileList }

    /// Whether there are files to list, or will be once they're read.
    private var hasFiles: Bool {
        switch commit.subject {
        case nil, .scattered: false
        case .commit, .comparison, .stash: true
        }
    }

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
            if let swapped = commit.comparison?.swapped {
                Button("Swap Commits", icon: .swap) {
                    model.compare(swapped)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.icon)
                .help("Swap Commits")
            }
            FileListCommands(list: fileList, closeFilter: closeFilter)
                .disabled(!hasFiles)
        } content: {
            switch commit.subject {
            case nil:
                note("Select a commit to view its changes.")
            case .scattered(let count):
                note("These \(count.formatted()) commits aren't one after another on one line, so they don't make one diff. Select a run of commits, or two to compare.")
            case .commit, .comparison, .stash:
                if let problem = commit.problem {
                    note(problem)
                } else if let info = commit.info {
                    ScrollViewReader { scroller in
                        ScrollView {
                            CommitDetails(info: info, commit: commit, model: model) { file, group in
                                isFocused = true
                                commit.select(file, in: group)
                            } toggleFolder: { path, group in
                                isFocused = true
                                fileList.toggleFolder(path, in: group)
                            }
                        }
                        // Each commit starts at the top of its message.
                        .id(commit.subject)
                        .focusable()
                        .focused($isFocused)
                        .focusEffectDisabled()
                        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                            commit.selectFile(by: press.key == .downArrow ? 1 : -1)
                            return .handled
                        }
                        .onChange(of: commit.fileSteps) {
                            if let path = commit.selectedFile.file?.path {
                                scroller.scrollTo(FileRow.ID(group: commit.selectedFile.group, path: path))
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
            }
        }
    }

    private func title(showingHash: Bool) -> some View {
        HStack(spacing: 4) {
            Text(titleText)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .padding(.leading, 4)
            if let detail = titleDetail, showingHash {
                Text(detail)
                    .font(.system(size: 12, design: commit.stash == nil && commit.comparison == nil ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
            if commit.hashToCopy != nil {
                Button("Copy Commit Hash", icon: .copy) {
                    commit.copyHash()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.icon)
                .help("Copy Commit Hash (\(RepositoryCommands.copyHashShortcut.symbols))")
            }
        }
    }

    /// What the header says the panel shows.
    private var titleText: String {
        switch commit.subject {
        case nil, .commit: "Commit"
        case .stash: "Stash"
        case .scattered(let count): "\(count.formatted()) Commits"
        case .comparison(let comparison):
            switch comparison.kind {
            case .run(let count, _): "\(count.formatted()) Commits"
            case .pair: "Compare"
            case .branch(let name, _, _, _): Ref.shortName(name)
            }
        }
    }

    /// What comes after the title in gray, which gives way first.
    private var titleDetail: String? {
        switch commit.subject {
        case .commit(let id): String(id.hex.prefix(8))
        case .stash(let stash): stash.name
        case .comparison(let comparison):
            switch comparison.kind {
            case .run: nil
            case .pair: comparison.from.map { "\($0.hex.prefix(8)) → \(comparison.to.hex.prefix(8))" }
            case .branch(_, let against, _, _): "since " + Ref.shortName(against)
            }
        case nil, .scattered: nil
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
        let group = commit.selectedFile.group
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

/// What the panel says about what's selected, and its files.
private struct CommitDetails: View {
    let info: CommitInfo
    let commit: SelectedCommit
    let model: RepositoryModel
    let select: (DiffFile, WorktreeChanges.Group?) -> Void
    let toggleFolder: (String, WorktreeChanges.Group?) -> Void
    /// It's one setting for every commit, so that moving through history with a
    /// long message out of the way keeps it out of the way.
    @AppStorage(CommitPanelSettings.collapsesBody) private var collapsesBody = false

    private var fileList: FileListModel { commit.fileList }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A filter's matches go at the top, because a long message could
            // otherwise leave them out of sight.
            if fileList.filter.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    about
                }
                .font(.system(size: 13))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1)
            }
            switch commit.files {
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
            case .loaded(let groups):
                if commit.stash != nil {
                    stashFiles(groups)
                } else {
                    let files = groups.first?.files ?? []
                    let rows = fileList.rows(of: files)
                    if rows.isEmpty, !fileList.filter.isEmpty {
                        NoMatchingFiles(filter: fileList.filter)
                    } else {
                        FilesSummary(files: fileList.matching(files), total: files.count, isMerge: commit.id != nil && info.parents.count > 1)
                            .id(FileRows.top)
                    }
                    FileRows(list: fileList, rows: rows, selectedFile: commit.selectedFile, select: { select($0, nil) }, toggleFolder: { toggleFolder($0, nil) })
                        .padding(.bottom, 6)
                }
            }
        }
    }

    /// What's said above the files, which depends on what's selected.
    @ViewBuilder private var about: some View {
        switch commit.subject {
        case .stash:
            Text(info.subject.isEmpty ? "This stash has no message." : info.subject)
                .fontWeight(.semibold)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                if let base = commit.stashBase {
                    HStack(spacing: 8) {
                        Text("Made on").foregroundStyle(.secondary)
                        CommitLink(id: base, isInHistory: model.hasCommit(base), help: "Select the commit in history") {
                            model.select(commit: base)
                        }
                    }
                }
                Text("\(Text("Date").foregroundStyle(.secondary))  \(date(info.author.time))")
            }
            .font(.system(size: 12))
        case .comparison(let comparison):
            ComparisonSummary(comparison: comparison, info: info, fromInfo: commit.fromInfo, model: model)
        case .commit, .scattered, nil:
            message
            people
            parents
        }
    }

    private func date(_ time: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(time)).formatted(date: .abbreviated, time: .shortened)
    }

    /// A stash's files, under the headings uncommitted changes would have, without
    /// their buttons, since a stash can't be changed from here.
    @ViewBuilder private func stashFiles(_ groups: [SelectedCommit.FileGroup]) -> some View {
        let shown = groups.filter { !fileList.rows(of: $0.files, in: $0.group).isEmpty }
        if shown.isEmpty {
            if fileList.filter.isEmpty {
                Text("This stash has no files.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                NoMatchingFiles(filter: fileList.filter)
            }
        }
        Color.clear.frame(height: 0).id(FileRows.top)
        ForEach(shown, id: \.group) { group in
            GroupHeading(title: group.group?.title ?? "", files: fileList.matching(group.files, in: group.group))
            FileRows(
                list: fileList,
                rows: fileList.rows(of: group.files, in: group.group),
                selectedFile: commit.selectedFile,
                select: { select($0, group.group) },
                toggleFolder: { toggleFolder($0, group.group) }
            )
        }
        Color.clear.frame(height: 6)
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
        let label = Text(title).foregroundStyle(.secondary)
        let email = signature.email.isEmpty ? "" : " <\(signature.email)>"
        let details = Text("\(email)  \(date(signature.time))").foregroundStyle(.secondary)
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
                    CommitLink(id: parent, isInHistory: model.hasCommit(parent), help: "Select the parent in history") {
                        model.select(commit: parent)
                    }
                }
            }
            .font(.system(size: 12))
        }
    }
}

/// What several commits shown as one diff are: a run of commits, two commits, or a
/// branch since it left another.
private struct ComparisonSummary: View {
    let comparison: SelectedCommit.Comparison
    /// The commit compared to.
    let info: CommitInfo
    /// The commit compared from, for two commits.
    let fromInfo: CommitInfo?
    let model: RepositoryModel

    var body: some View {
        switch comparison.kind {
        case .run(let count, let oldest):
            HStack(spacing: 4) {
                Text("All \(count.formatted()) as one diff, from")
                link(oldest)
                Text("to")
                link(comparison.to)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            Text(info.subject.isEmpty ? "This commit has no message." : info.subject)
                .fontWeight(.semibold)
                .lineLimit(2)
        case .pair:
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                if let from = comparison.from {
                    row("From", from, subject: fromInfo?.subject)
                }
                row("To", comparison.to, subject: info.subject)
            }
            .font(.system(size: 12))
        case .branch(_, let against, let count, let hasMore):
            let other = Ref.shortName(against)
            Group {
                if let base = comparison.from {
                    HStack(spacing: 4) {
                        Text(commits(count, hasMore: hasMore) + " since it left \(other) at")
                        link(base)
                    }
                } else {
                    Text("It has no commit in common with \(other), so this is everything in it.")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            if count > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Latest").foregroundStyle(.secondary).font(.system(size: 12))
                    Text(info.subject.isEmpty ? "This commit has no message." : info.subject)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                }
            }
        }
    }

    private func commits(_ count: Int, hasMore: Bool) -> String {
        if count == 0 { return "No commits" }
        if hasMore { return "More than \(count.formatted()) commits" }
        return count == 1 ? "1 commit" : "\(count.formatted()) commits"
    }

    private func link(_ id: ObjectID) -> some View {
        CommitLink(id: id, isInHistory: model.hasCommit(id), help: "Select the commit in history") {
            model.select(commit: id)
        }
        .foregroundStyle(.primary)
    }

    private func row(_ title: String, _ id: ObjectID, subject: String?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            link(id)
            Text(subject ?? "")
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The subject of a commit that has more to its message, which hides and shows
/// the rest. Clicking the subject does the same as the chevron after it, so
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
                Chevron(pointsDown: !isCollapsed)
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

/// A commit's short hash, which selects the commit in history.
private struct CommitLink: View {
    let id: ObjectID
    let isInHistory: Bool
    let help: String
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
        .help(isInHistory ? help : "History doesn't have this commit")
    }
}

/// How many files changed, and how many lines, or how many of them a filter left.
private struct FilesSummary: View {
    let files: [DiffFile]
    /// How many files changed.
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

/// A heading over one part of a stash: its title, how many files it has and how
/// many lines they change, or as many as a filter left.
private struct GroupHeading: View {
    let title: String
    let files: [DiffFile]

    var body: some View {
        let lines = files.compactMap(\.lines)
        let added = lines.reduce(0) { $0 + $1.added }
        let removed = lines.reduce(0) { $0 + $1.removed }
        HStack(spacing: 8) {
            Text(title)
                .fontWeight(.medium)
            Text(files.count, format: .number)
                .foregroundStyle(.secondary)
            if added + removed > 0 {
                LineCounts(added: added, removed: removed)
            }
        }
        .font(.system(size: 12))
        .frame(height: 20)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The names of the settings that the panel and the Settings window share.
enum CommitPanelSettings {
    static let collapsesBody = "collapsesCommitBody"
}
