import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Reading what's uncommitted in a worktree, against real git.
@Suite(.timeLimit(.minutes(1)))
struct WorktreeChangesTests {
    /// A repository with one commit, and a session for it.
    func makeRepository(files: [String: String] = ["a.txt": "one\ntwo\nthree\n"]) async throws -> (RepositorySession, String) {
        let repository = try makeTemporaryFolder() + "/repository"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: repository)
        try await runGit("config", "user.name", "Ana", in: repository)
        try await runGit("config", "user.email", "ana@example.com", in: repository)
        for (path, text) in files {
            try write(text, to: path, in: repository)
        }
        if !files.isEmpty {
            try await runGit("add", "--all", in: repository)
            try await runGit("commit", "--quiet", "--message=First", in: repository)
        }
        return (try await openSession(repository), repository)
    }

    func write(_ text: String, to path: String, in repository: String) throws {
        let file = URL(filePath: repository + "/" + path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func patchText(_ file: DiffFile, _ group: WorktreeChanges.Group, _ changes: WorktreeChanges, _ session: RepositorySession, in repository: String) async throws -> [String] {
        let patch = try await session.patch(of: file, from: .worktree(path: repository, group: group, head: changes.head))
        return patch.lines.filter { $0.kind == .added || $0.kind == .removed }.map {
            ($0.kind == .added ? "+" : "-") + String(decoding: patch.text(of: $0), as: UTF8.self)
        }
    }

    @Test func aCleanWorktreeHasNoChanges() async throws {
        let (session, repository) = try await makeRepository()
        let status = try await session.status(in: repository)
        #expect(status.fileCount == 0)
        #expect(status.head != nil)
        #expect(try await session.changes(in: repository) == status)
    }

    @Test func listsEveryKindOfChangeWithItsLineCounts() async throws {
        let (session, repository) = try await makeRepository(files: [
            "changed.txt": "one\ntwo\nthree\n",
            "both.txt": "one\ntwo\nthree\n",
            "deleted.txt": "gone\n",
            "staged-deleted.txt": "gone\ngone\n",
            "moved-old.txt": (1...40).map { "line \($0)\n" }.joined(),
            "mode.sh": "echo\n",
            "picture.png": "\0\u{1}\u{2}",
        ])
        try write("one\nTWO\nthree\n", to: "changed.txt", in: repository)
        try write("one\ntwo\nstaged\n", to: "both.txt", in: repository)
        try await runGit("add", "both.txt", in: repository)
        try write("one\nunstaged\nstaged\nmore\n", to: "both.txt", in: repository)
        try FileManager.default.removeItem(atPath: repository + "/deleted.txt")
        try await runGit("rm", "--quiet", "staged-deleted.txt", in: repository)
        try await runGit("mv", "moved-old.txt", "moved-new.txt", in: repository)
        try write("new\n", to: "staged-new.txt", in: repository)
        try await runGit("add", "staged-new.txt", in: repository)
        try write("\0\u{3}", to: "picture.png", in: repository)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repository + "/mode.sh")
        try await runGit("add", "mode.sh", in: repository)
        try write("a\nb\n", to: "folder/inner/untracked.txt", in: repository)

        let changes = try await session.changes(in: repository)
        func lines(_ files: [DiffFile], _ path: String) -> DiffFile.LineCounts?? {
            files.first { $0.path == path }.map(\.lines)
        }
        #expect(changes.fileCount == 9)
        #expect(changes.unstaged.map(\.path).sorted() == ["both.txt", "changed.txt", "deleted.txt", "picture.png"])
        #expect(changes.staged.map(\.path).sorted() == ["both.txt", "mode.sh", "moved-new.txt", "staged-deleted.txt", "staged-new.txt"])
        // Every untracked file is listed, rather than the folder that holds it.
        #expect(changes.untracked.map(\.path) == ["folder/inner/untracked.txt"])
        #expect(lines(changes.unstaged, "changed.txt") == DiffFile.LineCounts(added: 1, removed: 1))
        #expect(lines(changes.unstaged, "both.txt") == DiffFile.LineCounts(added: 2, removed: 1))
        #expect(lines(changes.staged, "both.txt") == DiffFile.LineCounts(added: 1, removed: 1))
        #expect(lines(changes.unstaged, "deleted.txt") == DiffFile.LineCounts(added: 0, removed: 1))
        #expect(lines(changes.staged, "staged-deleted.txt") == DiffFile.LineCounts(added: 0, removed: 2))
        #expect(lines(changes.staged, "staged-new.txt") == DiffFile.LineCounts(added: 1, removed: 0))
        #expect(lines(changes.unstaged, "picture.png") == .some(nil))
        let moved = try #require(changes.staged.first { $0.path == "moved-new.txt" })
        #expect(moved.oldPath == "moved-old.txt")
        #expect(moved.status == .renamed(similarity: 100))
        let mode = try #require(changes.staged.first { $0.path == "mode.sh" })
        #expect(mode.oldMode == 0o100644)
        #expect(mode.newMode == 0o100755)
    }

    @Test func readsTheStagedAndUnstagedPatchesOfAFile() async throws {
        let (session, repository) = try await makeRepository()
        try write("one\ntwo\nstaged\n", to: "a.txt", in: repository)
        try await runGit("add", "a.txt", in: repository)
        try write("one\nunstaged\nstaged\n", to: "a.txt", in: repository)

        let changes = try await session.changes(in: repository)
        #expect(changes.fileCount == 1)
        #expect(try await patchText(changes.staged[0], .staged, changes, session, in: repository) == ["-three", "+staged"])
        #expect(try await patchText(changes.unstaged[0], .unstaged, changes, session, in: repository) == ["-two", "+unstaged"])
    }

    @Test func readsARenamedFileAgainstItsOldPath() async throws {
        let (session, repository) = try await makeRepository(files: ["old.txt": (1...20).map { "line \($0)\n" }.joined()])
        try await runGit("mv", "old.txt", "new.txt", in: repository)
        try write((1...20).map { $0 == 3 ? "changed\n" : "line \($0)\n" }.joined(), to: "new.txt", in: repository)
        try await runGit("add", "new.txt", in: repository)

        let changes = try await session.changes(in: repository)
        #expect(changes.staged.count == 1)
        #expect(changes.staged[0].oldPath == "old.txt")
        #expect(try await patchText(changes.staged[0], .staged, changes, session, in: repository) == ["-line 3", "+changed"])
    }

    @Test func readsAnUntrackedFile() async throws {
        let (session, repository) = try await makeRepository()
        try write("a\nb\n", to: "folder/new file.txt", in: repository)
        let changes = try await session.changes(in: repository)
        let file = try #require(changes.untracked.first)
        #expect(file.status == .untracked)
        #expect(try await patchText(file, .untracked, changes, session, in: repository) == ["+a", "+b"])
    }

    @Test func saysWhenAnUntrackedFileIsBinaryOrEmpty() async throws {
        let (session, repository) = try await makeRepository()
        try write("\0\u{1}", to: "picture.png", in: repository)
        try write("", to: "empty.txt", in: repository)
        let changes = try await session.changes(in: repository)
        let source = PatchSource.worktree(path: repository, group: .untracked, head: changes.head)

        let binary = try await session.patch(of: try #require(changes.untracked.first { $0.path == "picture.png" }), from: source)
        #expect(binary.isBinary)
        #expect(binary.lines.isEmpty)
        let empty = try await session.patch(of: try #require(changes.untracked.first { $0.path == "empty.txt" }), from: source)
        #expect(!empty.isBinary)
        #expect(empty.lines.isEmpty)
    }

    @Test func readsAConflictAsTheWorktreeAgainstHead() async throws {
        let (session, repository) = try await makeRepository()
        try await runGit("switch", "--quiet", "--create", "other", in: repository)
        try write("theirs\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Theirs", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        try write("ours\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Ours", in: repository)
        var merge = GitCommand("merge", "--quiet", "other", in: repository)
        merge.successStatuses = [1]
        _ = try await TestGit.make().run(merge)

        let changes = try await session.changes(in: repository)
        #expect(changes.fileCount == 1)
        #expect(changes.unstaged.isEmpty)
        #expect(changes.staged.isEmpty)
        let file = try #require(changes.conflicted.first)
        #expect(file.status == .conflicted)
        let text = try await patchText(file, .conflicted, changes, session, in: repository)
        #expect(text.first == "+<<<<<<< HEAD")
        #expect(text.contains("+theirs"))
    }

    @Test func worksWithoutCommits() async throws {
        let (session, repository) = try await makeRepository(files: [:])
        try write("staged\n", to: "staged.txt", in: repository)
        try await runGit("add", "staged.txt", in: repository)
        try write("untracked\n", to: "untracked.txt", in: repository)

        let changes = try await session.changes(in: repository)
        #expect(changes.head == nil)
        #expect(changes.fileCount == 2)
        #expect(changes.staged.first?.lines == DiffFile.LineCounts(added: 1, removed: 0))
        #expect(try await patchText(changes.staged[0], .staged, changes, session, in: repository) == ["+staged"])
    }

    @Test func worksWithSHA256() async throws {
        let repository = try makeTemporaryFolder() + "/repository"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--object-format=sha256", in: repository)
        try write("staged\n", to: "staged.txt", in: repository)
        try await runGit("add", "staged.txt", in: repository)

        let session = try await openSession(repository)
        let changes = try await session.changes(in: repository)
        #expect(try await patchText(changes.staged[0], .staged, changes, session, in: repository) == ["+staged"])
    }

    @Test func treatsPathsAsNamesRatherThanPatterns() async throws {
        let (session, repository) = try await makeRepository(files: ["star*.txt": "one\n", "starry.txt": "two\n"])
        try write("ONE\n", to: "star*.txt", in: repository)
        try write("TWO\n", to: "starry.txt", in: repository)
        let changes = try await session.changes(in: repository)
        let file = try #require(changes.unstaged.first { $0.path == "star*.txt" })
        #expect(try await patchText(file, .unstaged, changes, session, in: repository) == ["-one", "+ONE"])
    }

    @Test func leavesOutAFileThatWasOnlyTouched() async throws {
        let (session, repository) = try await makeRepository()
        // A different time makes the index's record of the file out of date.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -1000)], ofItemAtPath: repository + "/a.txt")
        try write("new\n", to: "b.txt", in: repository)
        try await runGit("add", "b.txt", in: repository)
        try write("new\nmore\n", to: "b.txt", in: repository)

        let changes = try await session.changes(in: repository)
        #expect(changes.unstaged.map(\.path) == ["b.txt"])
        #expect(changes.unstaged[0].lines == DiffFile.LineCounts(added: 1, removed: 0))
        #expect(changes.fileCount == 1)
    }

    @Test func neverWritesTheIndex() async throws {
        let (session, repository) = try await makeRepository()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -1000)], ofItemAtPath: repository + "/a.txt")
        try write("x\n", to: "b.txt", in: repository)
        try await runGit("add", "b.txt", in: repository)
        try write("y\n", to: "b.txt", in: repository)
        try write("z\n", to: "c.txt", in: repository)

        let index = repository + "/.git/index"
        let before = try Data(contentsOf: URL(filePath: index))
        let time = try #require(try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date)

        let changes = try await session.changes(in: repository)
        for group in WorktreeChanges.Group.allCases {
            for file in changes[group] {
                _ = try await session.patch(of: file, from: .worktree(path: repository, group: group, head: changes.head))
            }
        }
        #expect(try Data(contentsOf: URL(filePath: index)) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date == time)
    }

    @Test(arguments: ["no", "false", "off", "0"])
    func leavesOutUntrackedFilesWhenTheyreTurnedOff(_ value: String) async throws {
        let (session, repository) = try await makeRepository()
        try write("untracked\n", to: "b.txt", in: repository)
        try write("changed\n", to: "a.txt", in: repository)
        try await runGit("config", "status.showUntrackedFiles", value, in: repository)
        let status = try await session.status(in: repository)
        #expect(status.untracked.isEmpty)
        #expect(status.fileCount == 1)
    }

    @Test func listsEveryUntrackedFileWhenGitWouldListOnlyTheFolder() async throws {
        let (session, repository) = try await makeRepository()
        try write("a\n", to: "folder/one.txt", in: repository)
        try write("b\n", to: "folder/two.txt", in: repository)
        try await runGit("config", "status.showUntrackedFiles", "normal", in: repository)
        #expect(try await session.status(in: repository).untracked.map(\.path) == ["folder/one.txt", "folder/two.txt"])
    }

    @Test func leavesOutIgnoredFiles() async throws {
        let (session, repository) = try await makeRepository(files: [".gitignore": "*.log\n"])
        try write("x\n", to: "ignored.log", in: repository)
        #expect(try await session.status(in: repository).fileCount == 0)
    }

    @Test func aPatchDoesntDependOnDiffSettings() async throws {
        let (session, repository) = try await makeRepository(files: [
            "a.txt": (1...20).map { "line \($0)\n" }.joined(),
            "converted.txt": "plain\n",
        ])
        try write((1...20).map { $0 == 10 ? "changed\n" : "line \($0)\n" }.joined(), to: "a.txt", in: repository)
        try write("new\n", to: "new.conv", in: repository)
        let marker = repository + "/.git/external-diff-ran"
        for (key, value) in [
            ("diff.context", "0"),
            ("diff.noprefix", "true"),
            ("diff.mnemonicPrefix", "true"),
            ("color.ui", "always"),
            ("diff.external", "touch \(marker)"),
            ("diff.conv.textconv", "touch \(marker); cat"),
            ("status.renames", "false"),
            ("status.relativePaths", "true"),
        ] {
            try await runGit("config", key, value, in: repository)
        }
        try write("*.conv diff=conv\n", to: ".git/info/attributes", in: repository)

        let changes = try await session.changes(in: repository)
        let file = try #require(changes.unstaged.first)
        let patch = try await session.patch(of: file, from: .worktree(path: repository, group: .unstaged, head: changes.head))
        #expect(patch.lines.filter { $0.kind == .context }.count == 6)
        let new = try #require(changes.untracked.first { $0.path == "new.conv" })
        #expect(try await patchText(new, .untracked, changes, session, in: repository) == ["+new"])
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func eachWorktreeHasItsOwnChanges() async throws {
        let (session, repository) = try await makeRepository()
        let linked = (repository as NSString).deletingLastPathComponent + "/linked"
        try await runGit("worktree", "add", "--quiet", "-b", "other", linked, in: repository)
        try write("changed\n", to: "a.txt", in: linked)
        try write("new\n", to: "b.txt", in: linked)

        #expect(try await session.status(in: repository).fileCount == 0)
        let changes = try await session.changes(in: linked)
        #expect(changes.fileCount == 2)
        let file = try #require(changes.unstaged.first)
        #expect(try await patchText(file, .unstaged, changes, session, in: linked).contains("+changed"))
    }

    /// A clone of a local folder with only commits, like the one for measuring
    /// history, where git status would fetch every tree in HEAD.
    @Test func doesntDownloadAnythingInAPartialClone() async throws {
        let (server, repository) = try await makeRepository(files: ["a/x/1.txt": "1\n", "a/y/2.txt": "2\n", "b/x/3.txt": "3\n"])
        guard server.git.installation.version >= GitVersion(major: 2, minor: 45) else { return }
        try await runGit("config", "uploadpack.allowFilter", "true", in: repository)
        try await runGit("config", "uploadpack.allowAnySHA1InWant", "true", in: repository)
        let clone = (repository as NSString).deletingLastPathComponent + "/clone"
        try await TestGit.make().run(GitCommand("clone", "--quiet", "--filter=tree:0", "--no-checkout", "file://" + repository, clone))

        func objects() async throws -> String {
            try await runGit("count-objects", "-v", in: clone)
        }
        let before = try await objects()
        let session = try await openSession(clone)
        await #expect(throws: GitError.self) { try await session.status(in: clone) }
        #expect(try await objects() == before)
    }

    @Test func aCloneWithoutBlobsStillListsItsChanges() async throws {
        let (server, repository) = try await makeRepository(files: ["a.txt": "one\n", "b.txt": "two\n"])
        #expect(server.location.format == .sha1)
        try await runGit("config", "uploadpack.allowFilter", "true", in: repository)
        try await runGit("config", "uploadpack.allowAnySHA1InWant", "true", in: repository)
        let clone = (repository as NSString).deletingLastPathComponent + "/clone"
        try await TestGit.make().run(GitCommand("clone", "--quiet", "--filter=blob:none", "file://" + repository, clone))
        try write("changed\n", to: "a.txt", in: clone)
        try write("new\n", to: "c.txt", in: clone)

        let status = try await openSession(clone).status(in: clone)
        #expect(status.unstaged.map(\.path) == ["a.txt"])
        #expect(status.untracked.map(\.path) == ["c.txt"])
    }

    @Test func stopsAtTheLimit() async throws {
        let (session, repository) = try await makeRepository()
        try write("new\n", to: "b.txt", in: repository)
        await #expect(throws: RepositoryError.tooManyChanges(limit: 10)) {
            try await ChangesLoader.status(in: repository, git: session.git, limit: 10)
        }
    }

    @Test func failsInABareRepository() async throws {
        let repository = try makeTemporaryFolder() + "/bare.git"
        try await TestGit.make().run(GitCommand("init", "--quiet", "--bare", repository))
        let session = try await openSession(repository)
        await #expect(throws: GitError.self) { try await session.status(in: repository) }
    }
}
