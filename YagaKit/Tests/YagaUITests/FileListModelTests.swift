import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import YagaUI

/// How the panels lay out changed files, what a filter leaves of them, and how
/// the selection moves through the rows.
@Suite(.timeLimit(.minutes(1)))
struct FileListModelTests {
    func file(_ path: String, added: Int = 1, removed: Int = 0, oldPath: String? = nil) -> DiffFile {
        DiffFile(status: .modified, path: path, oldPath: oldPath, oldMode: 0o100644, newMode: 0o100644, lines: .init(added: added, removed: removed))
    }

    func files(_ paths: String...) -> [DiffFile] {
        paths.map { file($0) }
    }

    /// The rows as the panel draws them: indented by depth, with a slash after a
    /// folder, and a closed folder's line counts.
    func drawn(_ rows: [FileRow]) -> [String] {
        rows.map { row in
            let indent = String(repeating: "  ", count: row.depth)
            switch row.content {
            case .file(let file):
                return indent + file.name
            case .folder(_, let title, let isCollapsed, let lines):
                return indent + title + "/" + (isCollapsed ? " +\(lines.added) -\(lines.removed)" : "")
            }
        }
    }

    func tree() -> FileListModel {
        let list = FileListModel()
        list.layout = .tree
        return list
    }

    @Test func aListKeepsTheOrderGitGaveIt() {
        let list = FileListModel()
        let rows = list.rows(of: files("Z.md", "docs/b.md", "docs/a.md"))
        #expect(rows.compactMap(\.file?.path) == ["Z.md", "docs/b.md", "docs/a.md"])
        #expect(rows.allSatisfy { $0.depth == 0 })
        #expect(list.rowsShowFolders)
    }

    @Test func aTreeListsFoldersThenFilesFromAToZ() {
        let list = tree()
        let rows = list.rows(of: files("README.md", "CLAUDE.md", "web/app.js", "docs/b.md", "docs/a.md", "docs/guide/c.md", "Web2/d.js"))
        #expect(drawn(rows) == [
            "docs/",
            "  guide/",
            "    c.md",
            "  a.md",
            "  b.md",
            "web/",
            "  app.js",
            "Web2/",
            "  d.js",
            "CLAUDE.md",
            "README.md",
        ])
        #expect(!list.rowsShowFolders)
    }

    @Test func numbersInNamesCountAsNumbers() {
        #expect(drawn(tree().rows(of: files("v10/a", "v9/a", "file10", "file9"))) == [
            "v9/", "  a", "v10/", "  a", "file9", "file10",
        ])
    }

    @Test func aFolderWithNothingButAFolderSharesItsRow() {
        let rows = tree().rows(of: files("web/src/app/a.js", "web/src/app/b.js", "lib/one/a.c", "lib/two/b.c", "lib/c.c"))
        #expect(drawn(rows) == [
            "lib/",
            "  one/",
            "    a.c",
            "  two/",
            "    b.c",
            "  c.c",
            "web/src/app/",
            "  a.js",
            "  b.js",
        ])
    }

    @Test func aFileReplacedByAFolderHasRowsOfTheirOwn() {
        let rows = tree().rows(of: files("thing", "thing/inside"))
        #expect(drawn(rows) == ["thing/", "  inside", "thing"])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func aClosedFolderHidesWhatsInItAndSaysHowManyLinesChange() {
        let list = tree()
        let files = [
            file("src/a.c", added: 3, removed: 1),
            file("src/lib/b.c", added: 5, removed: 2),
            DiffFile(status: .modified, path: "src/image.bin", oldMode: 0o100644, newMode: 0o100644),
            file("top.c"),
        ]
        list.toggleFolder("src")
        #expect(drawn(list.rows(of: files)) == ["src/ +8 -3", "top.c"])
        list.toggleFolder("src")
        #expect(drawn(list.rows(of: files)) == ["src/", "  lib/", "    b.c", "  a.c", "  image.bin", "top.c"])
    }

    @Test func aClosedFolderStaysClosedInTheNextCommit() {
        let list = tree()
        list.toggleFolder("src")
        #expect(drawn(list.rows(of: files("src/a.c", "b.c"))) == ["src/ +1 -0", "b.c"])
        #expect(drawn(list.rows(of: files("src/z.c", "src/y.c"))) == ["src/ +2 -0"])
    }

    @Test func eachGroupClosesItsOwnFolders() {
        let list = tree()
        let files = files("src/a.c")
        list.toggleFolder("src", in: .staged)
        #expect(drawn(list.rows(of: files, in: .staged)) == ["src/ +1 -0"])
        #expect(drawn(list.rows(of: files, in: .unstaged)) == ["src/", "  a.c"])
        #expect(drawn(list.rows(of: files)) == ["src/", "  a.c"])
    }

    @Test func aFilterLeavesARowForEachMatchInEitherLayout() {
        let files = files("docs/inbox.md", "internal/INBOX/a.go", "internal/b.go")
        for list in [FileListModel(), tree()] {
            list.filter = "inbox"
            let rows = list.rows(of: files)
            #expect(rows.compactMap(\.file?.path) == ["docs/inbox.md", "internal/INBOX/a.go"])
            #expect(rows.allSatisfy { $0.depth == 0 })
            #expect(list.rowsShowFolders)
            #expect(list.matching(files).count == 2)
        }
    }

    @Test func aFilterLooksInClosedFolders() {
        let list = tree()
        list.toggleFolder("docs")
        list.filter = "a.md"
        #expect(drawn(list.rows(of: files("docs/a.md", "docs/b.md"))) == ["a.md"])
    }

    @Test func aFilterFindsWhereAFileCameFrom() {
        let list = FileListModel()
        list.filter = "old"
        let rows = list.rows(of: [file("new/a.c", oldPath: "old/a.c"), file("new/b.c")])
        #expect(rows.compactMap(\.file?.path) == ["new/a.c"])
    }

    @Test func rowsFollowEverythingThatDecidesThem() {
        let list = FileListModel()
        let files = files("docs/a.md", "b.md")
        #expect(drawn(list.rows(of: files)) == ["a.md", "b.md"])
        list.layout = .tree
        #expect(drawn(list.rows(of: files)) == ["docs/", "  a.md", "b.md"])
        list.toggleFolder("docs")
        #expect(drawn(list.rows(of: files)) == ["docs/ +1 -0", "b.md"])
        list.filter = "a"
        #expect(drawn(list.rows(of: files)) == ["a.md"])
        list.closeFilter()
        #expect(drawn(list.rows(of: files)) == ["docs/ +1 -0", "b.md"])
        #expect(drawn(list.rows(of: self.files("c.md"))) == ["c.md"])
    }

    @Test func closingTheFilterClearsIt() {
        let list = FileListModel()
        list.showFilter()
        #expect(list.isFilterShown)
        #expect(list.wantsFilterFocus)
        list.filter = "a"
        list.closeFilter()
        #expect(!list.isFilterShown)
        #expect(list.filter.isEmpty)
    }

    @Test func revealingAFileOpensTheFoldersItsIn() {
        let list = tree()
        let files = files("src/lib/a.c", "src/lib/b.c", "src/c.c", "srcs/d.c")
        list.toggleFolder("src")
        list.toggleFolder("src/lib")
        list.toggleFolder("srcs")
        list.reveal("src/lib/a.c")
        #expect(drawn(list.rows(of: files)) == ["src/", "  lib/", "    a.c", "    b.c", "  c.c", "srcs/ +1 -0"])
    }

    // MARK: Moving through the rows

    @Test func movingGoesPastFolders() throws {
        let rows = tree().rows(of: files("docs/a.md", "src/b.c", "top.c"))
        #expect(rows.file(1, from: "docs/a.md", in: nil)?.file?.path == "src/b.c")
        #expect(rows.file(1, from: "src/b.c", in: nil)?.file?.path == "top.c")
        #expect(rows.file(-1, from: "src/b.c", in: nil)?.file?.path == "docs/a.md")
        #expect(rows.file(2, from: "docs/a.md", in: nil)?.file?.path == "top.c")
        // It stops at the ends.
        #expect(rows.file(1, from: "top.c", in: nil) == nil)
        #expect(rows.file(-1, from: "docs/a.md", in: nil) == nil)
    }

    @Test func movingGoesPastClosedFolders() {
        let list = tree()
        list.toggleFolder("b")
        let rows = list.rows(of: files("a/1", "b/2", "c/3"))
        #expect(rows.file(1, from: "a/1", in: nil)?.file?.path == "c/3")
        #expect(rows.file(-1, from: "c/3", in: nil)?.file?.path == "a/1")
    }

    @Test func movingFromAFileInAClosedFolderStartsAtTheFolder() {
        let list = tree()
        list.toggleFolder("b")
        let rows = list.rows(of: files("a/1", "b/2", "c/3"))
        #expect(rows.file(1, from: "b/2", in: nil)?.file?.path == "c/3")
        #expect(rows.file(-1, from: "b/2", in: nil)?.file?.path == "a/1")
    }

    @Test func movingFromAFileTheFilterLeftOutGoesToTheFirstMatch() {
        let list = FileListModel()
        list.filter = "match"
        let rows = list.rows(of: files("a", "match-1", "match-2"))
        #expect(rows.file(1, from: "a", in: nil)?.file?.path == "match-1")
        #expect(rows.file(-1, from: "a", in: nil)?.file?.path == "match-1")
    }

    @Test func movingTellsTheSameFileInTwoGroupsApart() {
        let list = tree()
        let files = files("a", "b")
        let rows = list.rows(of: files, in: .unstaged) + list.rows(of: files, in: .staged)
        let next = rows.file(1, from: "b", in: .unstaged)
        #expect(next?.file?.path == "a")
        #expect(next?.group == .staged)
        #expect(rows.file(1, from: "b", in: .staged) == nil)
    }

    // MARK: In the panels

    /// The `every-way` commit of the `changes` repository, whose files are
    /// `image.bin`, `kind.txt`, `lib/moved.txt`, `notes.opaque`, `run.sh`,
    /// `src/gone.txt`, `src/new.txt` and `with space.txt`.
    func everyWay(_ prepare: (FileListModel) -> Void) async throws -> SelectedCommit {
        let repository = try await Fixture.repository("changes")
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        let commit = SelectedCommit(session: session)
        prepare(commit.fileList)
        let command = GitCommand("rev-parse", "every-way^{commit}", in: session.location.commonDirectory)
        commit.show(try #require(ObjectID(hex: try await session.git.text(command))))
        await settled(commit)
        return commit
    }

    func settled(_ commit: SelectedCommit) async {
        await commit.loading?.value
        await commit.selectedFile.loading?.value
    }

    @Test func aCommitSelectsTheFirstFileOfTheTree() async throws {
        let commit = try await everyWay { $0.layout = .tree }
        #expect(commit.selectedFile.file?.path == "lib/moved.txt")
    }

    @Test func aCommitSelectsTheFirstFileThatShows() async throws {
        let commit = try await everyWay { list in
            list.layout = .tree
            list.toggleFolder("lib")
        }
        #expect(commit.selectedFile.file?.path == "src/gone.txt")
    }

    @Test func aCommitSelectsTheFirstMatch() async throws {
        let commit = try await everyWay { $0.filter = "new" }
        #expect(commit.selectedFile.file?.path == "src/new.txt")
    }

    @Test func aCommitWithNoMatchesStillShowsADiff() async throws {
        let commit = try await everyWay { $0.filter = "nothing like this" }
        #expect(commit.selectedFile.file?.path == "image.bin")
    }

    @Test func aCommitMovesThroughTheTreeInItsOrder() async throws {
        let commit = try await everyWay { $0.layout = .tree }
        var seen = [commit.selectedFile.file?.path]
        for _ in 0..<8 {
            commit.selectFile(by: 1)
            seen.append(commit.selectedFile.file?.path)
        }
        await settled(commit)
        #expect(seen == [
            "lib/moved.txt", "src/gone.txt", "src/new.txt", "image.bin", "kind.txt", "notes.opaque", "run.sh", "with space.txt",
            // It stops at the end.
            "with space.txt",
        ])
    }

    @Test func aFilterNarrowsWhatACommitMovesThrough() async throws {
        let commit = try await everyWay { $0.filter = "src/" }
        #expect(commit.selectedFile.file?.path == "src/gone.txt")
        commit.selectFile(by: 1)
        #expect(commit.selectedFile.file?.path == "src/new.txt")
        commit.selectFile(by: 1)
        #expect(commit.selectedFile.file?.path == "src/new.txt")
        commit.selectFirstFile()
        #expect(commit.selectedFile.file?.path == "src/gone.txt")
        await settled(commit)
    }

    @Test func narrowingLeavesTheSelectedFileAlone() async throws {
        let commit = try await everyWay { _ in }
        commit.fileList.filter = "src/"
        #expect(commit.selectedFile.file?.path == "image.bin")
        // Stepping from it goes to the first match.
        commit.selectFile(by: 1)
        #expect(commit.selectedFile.file?.path == "src/gone.txt")
        await settled(commit)
    }
}
