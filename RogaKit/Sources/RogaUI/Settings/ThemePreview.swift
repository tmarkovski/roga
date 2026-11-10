import AppKit
import CommitGraph
import DiffUI
import GitCore
import HistoryUI
import SwiftUI

/// A cutout of the window under Theme and Colors in Settings › Appearance: a few
/// commits with their graph and branches, and under them a commit's files beside
/// a diff. Those are where a color theme shows most, so choosing another theme,
/// or light or dark, shows here what it does before the sheet closes.
///
/// The commit list's cell, the panels' rows and the diff's text view draw it,
/// from a history, files and a patch that are made up, so it looks like the
/// window whatever changes there. It's a picture: nothing in it takes a click.
struct ThemePreview: View {
    /// How wide the files are, which leaves a diff's lines about 40 columns.
    private static let filesWidth: CGFloat = 220
    /// The room above and below the files, which gives them the diff's height.
    private static let filesInset: CGFloat = 7

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            CommitRowsSample()
                .frame(height: CommitRowsPicture.height(rows: ThemeSample.rows.count))
                // The first row stands clear of the edge. The last one doesn't,
                // because its lines go on down past it.
                .padding(.top, 4)
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
            HStack(spacing: 0) {
                files
                    .frame(width: Self.filesWidth)
                Rectangle()
                    .fill(Palette.separator)
                    .frame(width: 1)
                DiffSample()
            }
            .frame(height: ThemeSample.diffHeight)
        }
        // The panels' own surface, which the colors are chosen to read on.
        .background(Palette.surface)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Palette.separator, lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        // One picture to VoiceOver, since what's in it is made up.
        .accessibilityLabel("Preview of history, changed files and a diff in the theme and colors chosen")
        .accessibilityAddTraits(.isImage)
    }

    private var files: some View {
        VStack(spacing: 0) {
            ForEach(ThemeSample.fileRows) { row in
                switch row.content {
                case .file(let file):
                    ChangedFileRow(file: file, isSelected: file.path == ThemeSample.selectedPath, depth: row.depth, showsFolder: false) {}
                case .folder(let path, let title, let isCollapsed, let lines):
                    FolderRow(path: path, title: title, isCollapsed: isCollapsed, lines: lines, depth: row.depth) {}
                }
            }
        }
        .padding(.vertical, Self.filesInset)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// What the preview shows, none of which is in any repository.
enum ThemeSample {
    struct Commit {
        /// The start of its ID, which is all a row shows.
        let id: String
        var parents: [String] = []
        let minutesAgo: Int
        var subject = ""
        var badges: [CommitRowContent.Badge] = []
    }

    /// A branch someone is on, one commit past `main`, which has two merges in
    /// it, with another local branch above and one that's only on the remote
    /// below. Laid out, that's four lanes side by side within six rows, the
    /// current branch's badge and ring, another branch's name, and a remote's and
    /// a tag's gray. The last commit is what the lines run down to, below what shows.
    static let commits = [
        Commit(
            id: "5d81f0c3", parents: ["1c0be7a4"], minutesAgo: 12,
            subject: "Show what an agent is waiting for",
            badges: [.init(title: "agent-hooks", kind: .branch, refName: "refs/heads/agent-hooks")]
        ),
        Commit(
            id: "e47a92b6", parents: ["9b3c5e18"], minutesAgo: 47,
            subject: "Preview each color theme",
            badges: [.init(title: "theme-colors", kind: .currentBranch, refName: "refs/heads/theme-colors")]
        ),
        Commit(
            id: "9b3c5e18", parents: ["3fa06d27", "c2e9417d"], minutesAgo: 190,
            subject: "Merge branch 'sidebar-groups'",
            badges: [.init(title: "main", kind: .branch, refName: "refs/heads/main", upstream: "refs/remotes/origin/main")]
        ),
        Commit(id: "c2e9417d", parents: ["1c0be7a4"], minutesAgo: 320, subject: "Group repositories by organization"),
        Commit(
            id: "3fa06d27", parents: ["1c0be7a4", "a68d2f95"], minutesAgo: 1_560,
            subject: "Merge branch 'fix-fetch'",
            badges: [.init(title: "v0.9.0", kind: .tag, refName: "refs/tags/v0.9.0")]
        ),
        Commit(
            id: "a68d2f95", parents: ["1c0be7a4"], minutesAgo: 1_740,
            subject: "Retry a fetch that timed out",
            badges: [.init(title: "origin/fix-fetch", kind: .remoteBranch, refName: "refs/remotes/origin/fix-fetch")]
        ),
        Commit(id: "1c0be7a4", minutesAgo: 3_000),
    ]

    /// How many of the commits show, which leaves out the one they all come from.
    static let shownRows = 6
    /// The commit `HEAD` is on, which is the one whose files show underneath.
    static let selectedRow = 1

    /// The rows, laid out the way history's are.
    static let rows = (try? rows(now: Date())) ?? []

    /// Orders the commits and lays out their lanes with what history uses, so the
    /// graph is the one the list would draw for them.
    static func rows(now: Date) throws -> [CommitRowContent] {
        func id(_ start: String) throws -> ObjectID {
            guard let id = ObjectID(hex: start + String(repeating: "0", count: ObjectFormat.sha1.hexLength - start.count)) else {
                throw CocoaError(.formatting)
            }
            return id
        }
        let seconds = Int64(now.timeIntervalSince1970)
        func time(_ commit: Commit) -> Int64 {
            seconds - Int64(commit.minutesAgo) * 60
        }
        let graph = try CommitGraph(format: .sha1).adding(commits.map { commit in
            CommitGraph.NewerCommit(id: try id(commit.id), parents: try commit.parents.map(id), commitTime: time(commit))
        })
        var byPosition: [CommitGraph.Position: Commit] = [:]
        for commit in commits {
            if let position = graph.position(of: try id(commit.id)) { byPosition[position] = commit }
        }
        let tips = try commits.filter { !$0.badges.isEmpty }.compactMap { graph.position(of: try id($0.id)) }
        var order = try HistoryOrder(graph: graph, tips: tips, sort: .topological)
        let ordered = try order.next(Int.max)
        var lanes = LaneLayout(graph: graph)
        try lanes.append(ordered, isComplete: true)
        return ordered.prefix(shownRows).enumerated().compactMap { row, position in
            guard let commit = byPosition[position] else { return nil }
            return CommitRowContent(
                shortID: commit.id,
                badges: commit.badges,
                subject: commit.subject,
                date: RepositoryModel.format(time(commit), now: now),
                lanes: lanes.row(row)
            )
        }
    }

    /// The files the selected commit changed: one added, one changed and one gone.
    static let files = [
        DiffFile(status: .modified, path: selectedPath, oldMode: 0o100644, newMode: 0o100644, lines: .init(added: 2, removed: 1)),
        DiffFile(status: .added, path: "Sources/Badges/Preview.swift", oldMode: 0, newMode: 0o100644, lines: .init(added: 48, removed: 0)),
        DiffFile(status: .deleted, path: "Sources/Badges/Swatch.swift", oldMode: 0o100644, newMode: 0, lines: .init(added: 0, removed: 23)),
    ]

    /// The file whose diff shows.
    static let selectedPath = "Sources/Badges/Badge.swift"

    /// The files as a tree, under their folder.
    static let fileRows: [FileRow] = {
        let list = FileListModel()
        list.layout = .tree
        return list.rows(of: files)
    }()

    /// What changed in the selected file, as git would print it. A line that's
    /// replaced has the words that differ marked, as well as the lines' tints.
    static let patchText = """
    @@ -18,3 +18,4 @@ struct Badge {
         let name: String
    -    let fill = Color.green
    +    let fill = theme.current
    +    let text = theme.onCurrent
         var isCurrent = false

    """

    static let patch = (try? PatchParser.parse(Array(patchText.utf8))) ?? FilePatch(bytes: [], lines: [])

    /// How tall the diff is, which is what shows every line of the patch.
    static let diffHeight = DiffTextController.height(lines: patch.lines.count)
}

/// The sample's commits, drawn by the commit list's cell.
private struct CommitRowsSample: NSViewRepresentable {
    func makeNSView(context: Context) -> CommitRowsPicture {
        CommitRowsPicture(rows: ThemeSample.rows, selectedRow: ThemeSample.selectedRow)
    }

    func updateNSView(_ view: CommitRowsPicture, context: Context) {}
}

/// The sample's patch in the diff panel's text view, with its line numbers and
/// the bars beside its lines.
private struct DiffSample: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class Coordinator {
        private let controller = DiffTextController()
        let view: NSView

        init() {
            controller.isPicture = true
            // A document shows in one text view at a time, so each sample has its own.
            controller.show(DiffTextBuilder.document(forShort: ThemeSample.patch))
            view = PictureView(of: controller.view)
        }
    }
}

/// Holds a view that's only there to be looked at: the pointer goes through it to
/// what's behind, so the page scrolls under it, and VoiceOver doesn't go inside.
private final class PictureView: NSView {
    init(of view: NSView) {
        super.init(frame: .zero)
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Pictures are made in code.")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}
