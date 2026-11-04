import CommitGraph
import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

@Suite(.timeLimit(.minutes(1)))
struct RepositorySessionTests {
    @Test func readsCommits() async throws {
        let session = try await openSession(try await Fixture.repository("basic"))
        let ids = try [
            Fixture.Basic.main,
            Fixture.Basic.feature,
            // A tree, and an ID the repository doesn't have.
            Fixture.Basic.mainTree,
            String(repeating: "0", count: 40),
        ].map { try #require(ObjectID(hex: $0)) }
        let commits = try await session.commits(ids)

        try #require(commits.count == 4)
        let main = try #require(commits[0])
        #expect(main.id == ids[0])
        #expect(main.subject == "Change the app")
        #expect(main.message == "Change the app\n\nThe body says why.\n")
        #expect(main.author == Signature(name: "Ana Kovač", email: "ana@example.com", time: 1767434400, timeZoneOffset: 0))
        #expect(main.parents == [ObjectID(hex: Fixture.Basic.mainHistory[1])])
        #expect(commits[1]?.author.name == "Sam Lee")
        #expect(commits[2] == nil)
        #expect(commits[3] == nil)
    }

    @Test func listsWorktrees() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let folder = (repository as NSString).deletingLastPathComponent
        try await runGit("worktree", "add", "--quiet", folder + "/notes", "feature", in: repository)
        try await runGit("worktree", "add", "--quiet", "--detach", folder + "/old", "main~2", in: repository)

        // From a linked worktree, the main one still comes first.
        let session = try await openSession(folder + "/notes")
        let main = try #require(ObjectID(hex: Fixture.Basic.main))
        let feature = try #require(ObjectID(hex: Fixture.Basic.feature))
        let first = try #require(ObjectID(hex: Fixture.Basic.mainHistory[2]))
        #expect(try await session.worktrees() == [
            Worktree(path: repository, head: main, branch: "refs/heads/main", isMain: true),
            Worktree(path: folder + "/notes", head: feature, branch: "refs/heads/feature"),
            Worktree(path: folder + "/old", head: first),
        ])
    }

    @Test func loadsEachWorktreesHistory() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let notes = (repository as NSString).deletingLastPathComponent + "/notes"
        try await runGit("worktree", "add", "--quiet", notes, "feature", in: repository)
        let session = try await openSession(repository)

        let main = try #require(try await loadHistory(session).last)
        #expect(main.refs.currentBranch == "refs/heads/main")
        #expect(main.head == main.graph.position(of: try #require(ObjectID(hex: Fixture.Basic.main))))

        var linked: History?
        for try await history in session.history(in: notes, sort: .topological) {
            linked = history
        }
        let history = try #require(linked)
        #expect(history.refs.currentBranch == "refs/heads/feature")
        #expect(history.head == history.graph.position(of: try #require(ObjectID(hex: Fixture.Basic.feature))))
        #expect(Set(history.ids) == Set(main.ids))
    }

    @Test func opensTheGitDirectory() async throws {
        let repository = try await Fixture.repository("basic")
        let session = try await openSession(repository + "/.git")
        #expect(session.location.worktree == nil)
        #expect(session.location.name == "basic")
        #expect(try await session.worktrees().map(\.path) == [repository])
        let history = try #require(try await loadHistory(session).last)
        #expect(history.refs.currentBranch == "refs/heads/main")
        #expect(history.rows.count == 4)
    }

    @Test func outlastsTheWorktreeItWasOpenedFrom() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let notes = (repository as NSString).deletingLastPathComponent + "/notes"
        try await runGit("worktree", "add", "--quiet", notes, "feature", in: repository)
        let session = try await openSession(notes)
        try await runGit("worktree", "remove", notes, in: repository)

        #expect(try await session.worktrees().map(\.path) == [repository])
        let commits = try await session.commits([try #require(ObjectID(hex: Fixture.Basic.feature))])
        #expect(commits.first??.subject == "Add notes")
    }

    /// The files a tagged commit in the `changes` repository changed.
    func changedFiles(at tag: String, from folder: String? = nil) async throws -> [DiffFile] {
        let repository = try await Fixture.repository("changes")
        let session = try await openSession(folder ?? repository)
        let commit = try #require(ObjectID(hex: try await runGit("rev-parse", tag + "^{commit}", in: repository)))
        return try await session.changedFiles(in: commit)
    }

    @Test func listsTheFilesACommitChanged() async throws {
        let files = try await changedFiles(at: "every-way")
        func file(_ path: String) throws -> DiffFile { try #require(files.first { $0.path == path }) }

        #expect(files.map(\.path) == [
            "image.bin", "kind.txt", "lib/moved.txt", "notes.opaque", "run.sh", "src/gone.txt", "src/new.txt", "with space.txt",
        ])
        #expect(try file("src/new.txt").status == .added)
        #expect(try file("src/new.txt").lines == .init(added: 2, removed: 0))
        #expect(try file("src/new.txt").oldID == nil)
        #expect(try file("src/gone.txt").status == .deleted)
        #expect(try file("src/gone.txt").lines == .init(added: 0, removed: 1))
        #expect(try file("src/gone.txt").newID == nil)
        #expect(try file("with space.txt").status == .modified)
        #expect(try file("with space.txt").lines == .init(added: 1, removed: 0))
        #expect(try file("kind.txt").status == .typeChanged)
        #expect(try file("kind.txt").newMode == 0o120000)

        let moved = try file("lib/moved.txt")
        #expect(moved.oldPath == "moved.txt")
        #expect(moved.lines == .init(added: 1, removed: 0))
        guard case .renamed(let similarity) = moved.status else {
            Issue.record("\(moved.status) isn't a rename")
            return
        }
        #expect(similarity > 50)

        // Only its mode changed, so no lines did.
        #expect(try file("run.sh").oldMode == 0o100644)
        #expect(try file("run.sh").newMode == 0o100755)
        #expect(try file("run.sh").lines == .init(added: 0, removed: 0))

        #expect(try file("image.bin").lines == nil)
        // The repository's attributes say not to diff these.
        #expect(try file("notes.opaque").lines == nil)
    }

    @Test func listsEveryFileOfACommitWithoutParents() async throws {
        let files = try await changedFiles(at: "root")
        #expect(files.allSatisfy { $0.status == .added })
        #expect(files.contains { $0.path == "src/a\ttab.txt" })
    }

    @Test func comparesAMergeWithItsFirstParent() async throws {
        let files = try await changedFiles(at: "merge")
        #expect(files.map(\.path) == ["side.txt"])
    }

    @Test func findsNoFilesInAnEmptyCommit() async throws {
        #expect(try await changedFiles(at: "empty") == [])
    }

    @Test func failsOnACommitTheRepositoryDoesntHave() async throws {
        let session = try await openSession(try await Fixture.repository("basic"))
        let unknown = ObjectID(hex: String(repeating: "1", count: 40))!
        await #expect(throws: GitError.self) {
            try await session.changedFiles(in: unknown)
        }
    }

    @Test func listsChangedFilesAfterTheWorktreeWasRemoved() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let notes = (repository as NSString).deletingLastPathComponent + "/notes"
        try await runGit("worktree", "add", "--quiet", notes, "feature", in: repository)
        let session = try await openSession(notes)
        try await runGit("worktree", "remove", notes, in: repository)

        let files = try await session.changedFiles(in: try #require(ObjectID(hex: Fixture.Basic.feature)))
        #expect(files.map(\.path) == ["NOTES.md"])
    }

    @Test func listsChangedFilesInASHA256Repository() async throws {
        let repository = try await Fixture.History.sha256.repository()
        let session = try await openSession(repository)
        let commit = try #require(ObjectID(hex: try await runGit("rev-parse", "main", in: repository)))
        #expect(commit.format == .sha256)
        for file in try await session.changedFiles(in: commit) {
            #expect((file.newID ?? file.oldID)?.format == .sha256)
        }
    }

    func patch(of path: String, at tag: String) async throws -> FilePatch {
        let repository = try await Fixture.repository("changes")
        let session = try await openSession(repository)
        let commit = try #require(ObjectID(hex: try await runGit("rev-parse", tag + "^{commit}", in: repository)))
        let file = try #require(try await session.changedFiles(in: commit).first { $0.path == path })
        return try await session.patch(of: file, in: commit)
    }

    func summary(_ patch: FilePatch) -> [String] {
        patch.lines.map { String(decoding: patch.text(of: $0), as: UTF8.self) }
    }

    @Test func readsThePatchOfAFile() async throws {
        let patch = try await patch(of: "with space.txt", at: "every-way")
        #expect(summary(patch) == ["@@ -1 +1,2 @@", "keep", "more"])
        #expect(patch.lines.map(\.kind) == [.hunkHeader, .context, .added])
        #expect(patch.lines[2].newNumber == 2)
    }

    @Test func comparesARenamedFileWithItsOldPath() async throws {
        // Without the old path, git would show all of the file as new.
        let patch = try await patch(of: "lib/moved.txt", at: "every-way")
        #expect(patch.lines.filter { $0.kind == .added }.count == 1)
        #expect(patch.lines.filter { $0.kind == .added }.first?.newNumber == 7)
        #expect(patch.lines.first { $0.kind == .removed } == nil)
    }

    @Test func readsBothSidesOfAFileThatBecameAnotherKindOfFile() async throws {
        let patch = try await patch(of: "kind.txt", at: "every-way")
        #expect(summary(patch) == [
            "@@ -1 +0,0 @@", "link target",
            "@@ -0,0 +1 @@", "run.sh", "No newline at end of file",
        ])
    }

    @Test func readsNoLinesWhenOnlyTheModeChanged() async throws {
        #expect(try await patch(of: "run.sh", at: "every-way").lines.isEmpty)
    }

    @Test func readsNoLinesOfABinaryFile() async throws {
        #expect(try await patch(of: "image.bin", at: "every-way").lines.isEmpty)
        #expect(try await patch(of: "notes.opaque", at: "every-way").lines.isEmpty)
    }

    @Test func comparesAMergesFileWithItsFirstParent() async throws {
        #expect(summary(try await patch(of: "side.txt", at: "merge")) == ["@@ -0,0 +1 @@", "side"])
    }

    @Test func readsAFileOfACommitWithoutParents() async throws {
        #expect(summary(try await patch(of: "src/a\ttab.txt", at: "root")) == ["@@ -0,0 +1 @@", "tab"])
    }

    @Test func treatsAPathAsANameRatherThanAPattern() async throws {
        // As a pattern, this would match starry.txt too.
        #expect(summary(try await patch(of: "star*.txt", at: "root")) == ["@@ -0,0 +1 @@", "star"])
    }

    @Test func stopsReadingAPatchThatsTooLong() async throws {
        let repository = try await Fixture.repository("changes")
        let session = try await openSession(repository)
        let commit = try #require(ObjectID(hex: try await runGit("rev-parse", "root^{commit}", in: repository)))
        let file = try #require(try await session.changedFiles(in: commit).first { $0.path == "moved.txt" })
        await #expect(throws: RepositoryError.patchTooLarge(path: "moved.txt", limit: 10)) {
            try await DiffLoader.patch(of: file, in: commit, git: session.git, directory: repository, limit: 10)
        }
    }

    @Test func failsOnAPatchOfACommitTheRepositoryDoesntHave() async throws {
        let session = try await openSession(try await Fixture.repository("basic"))
        let unknown = ObjectID(hex: String(repeating: "1", count: 40))!
        let file = DiffFile(status: .added, path: "README.md", oldMode: 0, newMode: 0o100644)
        await #expect(throws: GitError.self) {
            try await session.patch(of: file, in: unknown)
        }
    }

    @Test func refusesCommitsOnceClosed() async throws {
        let session = try await openSession(try await Fixture.repository("basic"))
        await session.close()
        await #expect(throws: (any Error).self) {
            try await session.commits([try #require(ObjectID(hex: Fixture.Basic.main))])
        }
    }
}
