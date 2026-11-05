import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Discarding uncommitted changes and bringing them back, against real git.
@Suite(.timeLimit(.minutes(1)))
struct DiscardCommandsTests {
    /// Numbered lines, so that a change in one place leaves a hunk of its own.
    static let numbers = (1...60).map { "\($0)\n" }.joined()

    struct Work {
        var session: RepositorySession
        var path: String
        /// Stands in for the Trash, so that tests don't fill the real one.
        var trashFolder: String

        func read(_ file: String) throws -> String {
            try String(contentsOfFile: path + "/" + file, encoding: .utf8)
        }

        func write(_ text: String, to file: String) throws {
            let url = URL(filePath: path + "/" + file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func exists(_ file: String) -> Bool {
            FileManager.default.fileExists(atPath: path + "/" + file)
        }

        /// What git says is uncommitted, one short line per file.
        func short() async throws -> [String] {
            try await TestGit.make().text(GitCommand("status", "--short", "--untracked-files=all", in: path))
                .split(separator: "\n").map(String.init)
        }

        func changes() async throws -> WorktreeChanges {
            try await session.status(in: path)
        }

        func patch(of file: String) async throws -> FilePatch {
            let listed = try #require(try await changes().unstaged.first { $0.path == file })
            return try await session.patch(of: listed, from: .worktree(path: path, group: .unstaged, head: nil))
        }

        func hunkHeaders(of patch: FilePatch) -> [Int] {
            patch.lines.indices.filter { patch.lines[$0].kind == .hunkHeader }
        }

        func hunk(_ number: Int, of file: String) async throws -> HunkPatch {
            let patch = try await patch(of: file)
            return try #require(patch.hunk(at: hunkHeaders(of: patch)[number]))
        }
    }

    func work(files: [String: String] = ["a.txt": numbers, "b.txt": "b\n"], commit: Bool = true) async throws -> Work {
        let folder = try makeTemporaryFolder()
        let path = folder + "/repository"
        let trashFolder = folder + "/trash"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: trashFolder, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: path)
        try await runGit("config", "user.name", "Ana", in: path)
        try await runGit("config", "user.email", "ana@example.com", in: path)
        let trash = FileTrash { url in
            let moved = URL(filePath: trashFolder).appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: moved)
            return moved
        }
        let session = try await RepositorySession.open(containing: path, git: try await TestGit.make(), trash: trash)
        let work = Work(session: session, path: path, trashFolder: trashFolder)
        for (file, text) in files { try work.write(text, to: file) }
        if commit, !files.isEmpty {
            try await runGit("add", "--all", in: path)
            try await runGit("commit", "--quiet", "--message=First", in: path)
        }
        return work
    }

    /// The numbers, with some lines replaced, by line number.
    func numbers(replacing lines: [Int: String]) -> String {
        (1...60).map { (lines[$0] ?? String($0)) + "\n" }.joined()
    }

    // MARK: Hunks

    @Test func discardsOneHunkAndLeavesTheOthers() async throws {
        let work = try await work()
        try work.write(numbers(replacing: [3: "three", 30: "thirty"]), to: "a.txt")
        let discarded = try await work.session.discard(try await work.hunk(1, of: "a.txt"), in: work.path)
        #expect(try work.read("a.txt") == numbers(replacing: [3: "three"]))
        #expect(discarded.canBeBroughtBack)

        try await work.session.bringBack(discarded, in: work.path)
        #expect(try work.read("a.txt") == numbers(replacing: [3: "three", 30: "thirty"]))
    }

    @Test func theHunkThatGoesIsTheOneAskedForWhenAnotherHasTheSameLines() async throws {
        let work = try await work()
        // Two hunks make the same change, 8 lines apart, under a hunk that adds 8 lines.
        // git starts looking at the line number on the old side when it applies a patch
        // in reverse, and that's where the first of them is in the file as it is now.
        let lines = { (middle: String) in "same\nsame\nsame\n\(middle)\nsame\nsame\nsame\n" }
        let rest = (2...20).map { "\($0)\n" }.joined()
        let added = String(repeating: "new\n", count: 8)
        try work.write("1\n" + rest + lines("x") + "gap\n" + lines("x") + "tail\n", to: "c.txt")
        try await runGit("add", "c.txt", in: work.path)
        try await runGit("commit", "--quiet", "--message=More", in: work.path)

        let changed = "1\n" + added + rest + lines("changed") + "gap\n" + lines("changed") + "tail\n"
        try work.write(changed, to: "c.txt")
        let discarded = try await work.session.discard(try await work.hunk(2, of: "c.txt"), in: work.path)
        #expect(try work.read("c.txt") == "1\n" + added + rest + lines("changed") + "gap\n" + lines("x") + "tail\n")
        try await work.session.bringBack(discarded, in: work.path)
        #expect(try work.read("c.txt") == changed)
    }

    @Test func aHunkGoesBackWhereItWasBelowAHunkThatAddsLines() async throws {
        let work = try await work()
        // The same lines are in the file twice, 8 lines apart, and the first hunk adds 8
        // lines. So once the second hunk is gone, the first copy is exactly where the
        // second copy's old line number points, and that's where git would look first.
        let lines = { (middle: String) in "same\nsame\nsame\n\(middle)\nsame\nsame\nsame\n" }
        let rest = (2...20).map { "\($0)\n" }.joined()
        let added = String(repeating: "new\n", count: 8)
        try work.write("1\n" + rest + lines("x") + "gap\n" + lines("x") + "tail\n", to: "c.txt")
        try await runGit("add", "c.txt", in: work.path)
        try await runGit("commit", "--quiet", "--message=More", in: work.path)

        let changed = "1\n" + added + rest + lines("x") + "gap\n" + lines("changed") + "tail\n"
        try work.write(changed, to: "c.txt")
        let discarded = try await work.session.discard(try await work.hunk(1, of: "c.txt"), in: work.path)
        #expect(try work.read("c.txt") == "1\n" + added + rest + lines("x") + "gap\n" + lines("x") + "tail\n")
        try await work.session.bringBack(discarded, in: work.path)
        #expect(try work.read("c.txt") == changed)
    }

    @Test func discardingAHunkLeavesTheFilesModeAlone() async throws {
        let work = try await work()
        try work.write(numbers(replacing: [3: "three", 30: "thirty"]), to: "a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.path + "/a.txt")
        _ = try await work.session.discard(try await work.hunk(1, of: "a.txt"), in: work.path)
        #expect(try work.read("a.txt") == numbers(replacing: [3: "three"]))
        let attributes = try FileManager.default.attributesOfItem(atPath: work.path + "/a.txt")
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test func discardingAHunkLeavesWhatsStaged() async throws {
        let work = try await work()
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        try await runGit("add", "a.txt", in: work.path)
        try work.write(numbers(replacing: [3: "three", 30: "thirty"]), to: "a.txt")
        _ = try await work.session.discard(try await work.hunk(0, of: "a.txt"), in: work.path)
        #expect(try work.read("a.txt") == numbers(replacing: [3: "three"]))
        #expect(try await work.short() == ["M  a.txt"])
    }

    @Test func refusesAHunkWhoseLinesHaveChangedSince() async throws {
        let work = try await work()
        try work.write(numbers(replacing: [30: "thirty"]), to: "a.txt")
        let hunk = try await work.hunk(0, of: "a.txt")
        // An agent writes over the lines while the diff is on screen.
        try work.write(numbers(replacing: [30: "something else"]), to: "a.txt")
        await #expect(throws: GitError.self) {
            _ = try await work.session.discard(hunk, in: work.path)
        }
        #expect(try work.read("a.txt") == numbers(replacing: [30: "something else"]))
    }

    @Test func discardsAHunkOnlyThatsStillThereWhenTheLinesAroundItMoved() async throws {
        let work = try await work()
        try work.write(numbers(replacing: [30: "thirty"]), to: "a.txt")
        let hunk = try await work.hunk(0, of: "a.txt")
        // Lines arrive far above it, and they aren't what was on screen.
        try work.write("added by an agent\n" + numbers(replacing: [30: "thirty"]), to: "a.txt")
        _ = try await work.session.discard(hunk, in: work.path)
        #expect(try work.read("a.txt") == "added by an agent\n" + Self.numbers)
    }

    @Test func aHunkWithoutANewlineAtTheEndComesOutAndGoesBack() async throws {
        let work = try await work(files: ["n.txt": "one"])
        try work.write("one\ntwo", to: "n.txt")
        let discarded = try await work.session.discard(try await work.hunk(0, of: "n.txt"), in: work.path)
        #expect(try work.read("n.txt") == "one")
        try await work.session.bringBack(discarded, in: work.path)
        #expect(try work.read("n.txt") == "one\ntwo")
    }

    @Test func worksWhateverPrefixesGitIsSetToUse() async throws {
        let work = try await work()
        try await runGit("config", "diff.noprefix", "true", in: work.path)
        try await runGit("config", "diff.mnemonicPrefix", "true", in: work.path)
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        _ = try await work.session.discard(try await work.hunk(0, of: "a.txt"), in: work.path)
        #expect(try work.read("a.txt") == Self.numbers)
    }

    @Test func aHunkOfAFileWithSpacesInItsNameComesOut() async throws {
        let work = try await work(files: ["with space čćž.txt": Self.numbers])
        try work.write(numbers(replacing: [3: "three"]), to: "with space čćž.txt")
        _ = try await work.session.discard(try await work.hunk(0, of: "with space čćž.txt"), in: work.path)
        #expect(try work.read("with space čćž.txt") == Self.numbers)
    }

    // MARK: Files

    @Test func discardingAFileGoesBackToWhatsStaged() async throws {
        let work = try await work()
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        try await runGit("add", "a.txt", in: work.path)
        try work.write(numbers(replacing: [3: "three", 30: "thirty"]), to: "a.txt")
        let listed = try await work.changes().unstaged
        let discarded = try await work.session.discard(listed, from: .unstaged, in: work.path)
        #expect(try work.read("a.txt") == numbers(replacing: [3: "three"]))
        #expect(try await work.short() == ["M  a.txt"])

        try await work.session.bringBack(discarded, in: work.path)
        #expect(try work.read("a.txt") == numbers(replacing: [3: "three", 30: "thirty"]))
        #expect(try await work.short() == ["MM a.txt"])
    }

    @Test func aFileThatWasDeletedComesBackAndCanGoAgain() async throws {
        let work = try await work()
        try FileManager.default.removeItem(atPath: work.path + "/b.txt")
        let discarded = try await work.session.discard(try await work.changes().unstaged, from: .unstaged, in: work.path)
        #expect(try work.read("b.txt") == "b\n")
        try await work.session.bringBack(discarded, in: work.path)
        #expect(!work.exists("b.txt"))
        #expect(try await work.short() == [" D b.txt"])
    }

    @Test func aBinaryFileAndAModeChangeComeBack() async throws {
        let binary = (0..<4096).map { _ in UInt8.random(in: 0...255) }
        let work = try await work()
        try Data(binary).write(to: URL(filePath: work.path + "/bin.dat"))
        try await runGit("add", "bin.dat", in: work.path)
        try await runGit("commit", "--quiet", "--message=Binary", in: work.path)

        let changed = (0..<4096).map { _ in UInt8.random(in: 0...255) }
        try Data(changed).write(to: URL(filePath: work.path + "/bin.dat"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.path + "/b.txt")
        let discarded = try await work.session.discard(try await work.changes().unstaged, from: .unstaged, in: work.path)
        #expect(try await work.short().isEmpty)
        #expect(Array(try Data(contentsOf: URL(filePath: work.path + "/bin.dat"))) == binary)

        try await work.session.bringBack(discarded, in: work.path)
        #expect(Array(try Data(contentsOf: URL(filePath: work.path + "/bin.dat"))) == changed)
        let attributes = try FileManager.default.attributesOfItem(atPath: work.path + "/b.txt")
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test func treatsAFilesNameAsItsName() async throws {
        let names = ["*.txt", ":(top)a.txt", "with space.txt", "čćž.txt", "-dash.txt"]
        let work = try await work(files: Dictionary(uniqueKeysWithValues: (names + ["other.txt"]).map { ($0, "text\n") }))
        for name in names + ["other.txt"] { try work.write("changed\n", to: name) }
        // This one matches the first name as a pattern, and it has to stay as it is.
        let listed = try await work.changes().unstaged.filter { $0.path != "other.txt" }
        #expect(listed.count == names.count)
        _ = try await work.session.discard(listed, from: .unstaged, in: work.path)
        #expect(try await work.short() == [" M other.txt"])
        for name in names { #expect(try work.read(name) == "text\n") }
        #expect(try work.read("other.txt") == "changed\n")
    }

    @Test func aPatchTooLongToKeepCantBeBroughtBackButTheFileStillGoes() async throws {
        let work = try await work()
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        let discarded = try await DiscardCommands.discard(
            try await work.changes().unstaged,
            from: .unstaged,
            in: work.path,
            git: try await TestGit.make(),
            trash: work.session.trash,
            keptPatchLimit: 10
        )
        #expect(!discarded.canBeBroughtBack)
        #expect(try await work.short().isEmpty)
    }

    @Test func aFileAddedWithIntentToAddKeepsItsContentsInTheTrash() async throws {
        let work = try await work()
        try work.write("contents\n", to: "planned.txt")
        try await runGit("add", "-N", "planned.txt", in: work.path)
        let listed = try await work.changes().unstaged
        #expect(WorktreeChanges.Group.unstaged.discarding(listed[0]) == .trash)

        let discarded = try await work.session.discard(listed, from: .unstaged, in: work.path)
        #expect(!work.exists("planned.txt"))
        #expect(try await work.short().isEmpty)
        let trashed = try FileManager.default.contentsOfDirectory(atPath: work.trashFolder)
        #expect(try String(contentsOfFile: work.trashFolder + "/" + trashed[0], encoding: .utf8) == "contents\n")

        try await work.session.bringBack(discarded, in: work.path)
        #expect(try work.read("planned.txt") == "contents\n")
    }

    // MARK: Untracked files

    @Test func anUntrackedFileGoesToTheTrashAndComesBack() async throws {
        let work = try await work()
        try work.write("notes\n", to: "folder/deep/notes.md")
        try work.write("kept\n", to: "folder/kept.md")
        let notes = try #require(try await work.changes().untracked.first { $0.path == "folder/deep/notes.md" })
        let discarded = try await work.session.discard([notes], from: .untracked, in: work.path)
        #expect(!work.exists("folder/deep/notes.md"))
        // The folder it left empty goes too, and the one with something in it stays.
        #expect(!work.exists("folder/deep"))
        #expect(try work.read("folder/kept.md") == "kept\n")

        try await work.session.bringBack(discarded, in: work.path)
        #expect(try work.read("folder/deep/notes.md") == "notes\n")
    }

    @Test func anIgnoredFileKeepsItsFolder() async throws {
        let work = try await work()
        try work.write("*.log\n", to: ".gitignore")
        try await runGit("add", ".gitignore", in: work.path)
        try await runGit("commit", "--quiet", "--message=Ignore", in: work.path)
        try work.write("notes\n", to: "folder/notes.md")
        try work.write("log\n", to: "folder/run.log")
        _ = try await work.session.discard(try await work.changes().untracked, from: .untracked, in: work.path)
        #expect(!work.exists("folder/notes.md"))
        #expect(try work.read("folder/run.log") == "log\n")
    }

    @Test func aFileBackInItsPlaceStopsAnotherFromComingBack() async throws {
        let work = try await work()
        try work.write("notes\n", to: "notes.md")
        let discarded = try await work.session.discard(try await work.changes().untracked, from: .untracked, in: work.path)
        try work.write("written since\n", to: "notes.md")
        await #expect(throws: (any Error).self) {
            try await work.session.bringBack(discarded, in: work.path)
        }
        #expect(try work.read("notes.md") == "written since\n")
    }

    // MARK: What can't be discarded

    @Test func aRepositoryInsideTheWorktreeHasNoDiscard() async throws {
        let work = try await work()
        try await runGit("worktree", "add", "--quiet", "-b", "side", "inner", in: work.path)
        let nested = work.path + "/nested"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", in: nested)
        try Data("x\n".utf8).write(to: URL(filePath: nested + "/x.txt"))
        try await runGit("add", "--all", in: nested)
        try await runGit("-c", "user.name=A", "-c", "user.email=a@example.com", "commit", "--quiet", "--message=N", in: nested)

        let changes = try await work.changes()
        #expect(changes.untracked.map(\.path) == ["inner/", "nested/"])
        #expect(changes.untracked.allSatisfy { WorktreeChanges.Group.untracked.discarding($0) == nil })
        #expect(changes.trashedWhenDiscardingEverything.isEmpty)
        #expect(changes.stayingWhenDiscardingEverything.map(\.path) == ["inner/", "nested/"])
    }

    @Test func aSubmoduleHasNoDiscard() async throws {
        let inner = try await self.work(files: ["s.txt": "s\n"])
        let work = try await work()
        try await runGit("-c", "protocol.file.allow=always", "submodule", "--quiet", "add", inner.path, "module", in: work.path)
        try await runGit("commit", "--quiet", "--message=Module", in: work.path)
        try work.write("changed\n", to: "module/s.txt")
        let changes = try await work.changes()
        let module = try #require(changes.unstaged.first { $0.path == "module" })
        #expect(WorktreeChanges.Group.unstaged.discarding(module) == nil)
        #expect(changes.stayingWhenDiscardingEverything.map(\.path) == ["module"])
    }

    @Test func aStagedFileAndAConflictHaveNoDiscard() async throws {
        let work = try await work()
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        try await runGit("add", "a.txt", in: work.path)
        let staged = try #require(try await work.changes().staged.first)
        #expect(WorktreeChanges.Group.staged.discarding(staged) == nil)
        #expect(WorktreeChanges.Group.conflicted.discarding(staged) == nil)
    }

    // MARK: Everything

    @Test func everythingGoesBackToHeadAndComesBackAsItWas() async throws {
        let work = try await work()
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        try await runGit("add", "a.txt", in: work.path)
        try work.write(numbers(replacing: [3: "three", 30: "thirty"]), to: "a.txt")
        try work.write("new\n", to: "added.txt")
        try await runGit("add", "added.txt", in: work.path)
        try await runGit("mv", "b.txt", "moved.txt", in: work.path)
        try work.write("notes\n", to: "notes.md")
        let before = try await work.short()

        let changes = try await work.changes()
        let discarded = try await work.session.discardEverything(trashing: changes.trashedWhenDiscardingEverything, in: work.path)
        #expect(try await work.short().isEmpty)
        #expect(try work.read("a.txt") == Self.numbers)
        #expect(try work.read("b.txt") == "b\n")
        #expect(!work.exists("added.txt"))
        #expect(!work.exists("moved.txt"))
        #expect(!work.exists("notes.md"))

        try await work.session.bringBack(discarded, in: work.path)
        #expect(try await work.short() == before)
        #expect(try work.read("a.txt") == numbers(replacing: [3: "three", 30: "thirty"]))
        #expect(try work.read("notes.md") == "notes\n")
    }

    @Test func everythingLeavesARepositoryInsideTheWorktreeAlone() async throws {
        let work = try await work()
        try await runGit("worktree", "add", "--quiet", "-b", "side", "inner", in: work.path)
        try work.write("notes\n", to: "notes.md")
        let changes = try await work.changes()
        _ = try await work.session.discardEverything(trashing: changes.trashedWhenDiscardingEverything, in: work.path)
        #expect(work.exists("inner/.git"))
        #expect(try await work.short() == ["?? inner/"])
    }

    @Test func everythingTakesAFileAddedWithIntentToAdd() async throws {
        let work = try await work()
        try work.write("contents\n", to: "planned.txt")
        try await runGit("add", "-N", "planned.txt", in: work.path)
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        let discarded = try await work.session.discardEverything(trashing: try await work.changes().trashedWhenDiscardingEverything, in: work.path)
        #expect(try await work.short().isEmpty)
        try await work.session.bringBack(discarded, in: work.path)
        #expect(try work.read("planned.txt") == "contents\n")
        #expect(try work.read("a.txt") == numbers(replacing: [3: "three"]))
    }

    @Test func beforeTheFirstCommitEverythingStillGoesThoughStagedFilesCantComeBack() async throws {
        let work = try await work(files: ["a.txt": "a\n"], commit: false)
        try await runGit("add", "a.txt", in: work.path)
        try work.write("notes\n", to: "notes.md")
        let discarded = try await work.session.discardEverything(trashing: try await work.changes().trashedWhenDiscardingEverything, in: work.path)
        #expect(try await work.short().isEmpty)
        #expect(!work.exists("a.txt"))
        // The Trash still has what went there.
        #expect(discarded.canBeBroughtBack)
        try await work.session.bringBack(discarded, in: work.path)
        #expect(try work.read("notes.md") == "notes\n")
    }

    @Test func onlyUntrackedFilesLeaveNoStash() async throws {
        let work = try await work()
        try work.write("notes\n", to: "notes.md")
        let discarded = try await work.session.discardEverything(trashing: try await work.changes().trashedWhenDiscardingEverything, in: work.path)
        #expect(discarded.stash == nil)
        #expect(discarded.trashed.count == 1)
    }

    @Test func aStashLeavesNoRefBehind() async throws {
        let work = try await work()
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        _ = try await work.session.discardEverything(trashing: [], in: work.path)
        #expect(try await runGit("stash", "list", in: work.path).isEmpty)
    }
}
