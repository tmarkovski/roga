import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Staging and unstaging one hunk, against real git, with the discarding tests'
/// repositories.
extension DiscardCommandsTests {
    /// What the index has for a file.
    func staged(_ file: String, in work: Work) async throws -> String {
        // `text` would drop the file's last newline.
        try await TestGit.make().run(GitCommand("show", ":" + file, in: work.path)).text
    }

    /// A hunk of a file's staged or unstaged diff, placed as staging or unstaging
    /// places it.
    func hunk(_ number: Int, of file: String, under group: WorktreeChanges.Group, in work: Work) async throws -> HunkPatch {
        let changes = try await work.changes()
        let listed = try #require((group == .staged ? changes.staged : changes.unstaged).first { $0.path == file })
        let patch = try await work.session.patch(of: listed, from: .worktree(path: work.path, group: group, head: changes.head))
        return try #require(patch.hunk(at: work.hunkHeaders(of: patch)[number], placedOn: group == .staged ? .new : .old))
    }

    @Test func stagesOneHunkAndLeavesTheFileAlone() async throws {
        let work = try await work()
        let changed = numbers(replacing: [3: "three", 30: "thirty"])
        try work.write(changed, to: "a.txt")
        try await work.session.stage(try await hunk(1, of: "a.txt", under: .unstaged, in: work), in: work.path)
        #expect(try await staged("a.txt", in: work) == numbers(replacing: [30: "thirty"]))
        #expect(try work.read("a.txt") == changed)
        #expect(try await work.short() == ["MM a.txt"])
    }

    @Test func unstagesOneHunkAndLeavesTheFileAlone() async throws {
        let work = try await work()
        let changed = numbers(replacing: [3: "three", 30: "thirty"])
        try work.write(changed, to: "a.txt")
        try await runGit("add", "a.txt", in: work.path)
        try await work.session.unstage(try await hunk(0, of: "a.txt", under: .staged, in: work), in: work.path)
        #expect(try await staged("a.txt", in: work) == numbers(replacing: [30: "thirty"]))
        #expect(try work.read("a.txt") == changed)
        #expect(try await work.short() == ["MM a.txt"])
    }

    @Test func stagingAndUnstagingEveryHunkGoesBackToTheStart() async throws {
        let work = try await work()
        try work.write(numbers(replacing: [3: "three", 30: "thirty"]), to: "a.txt")
        try await work.session.stage(try await hunk(0, of: "a.txt", under: .unstaged, in: work), in: work.path)
        try await work.session.stage(try await hunk(0, of: "a.txt", under: .unstaged, in: work), in: work.path)
        #expect(try await work.short() == ["M  a.txt"])
        try await work.session.unstage(try await hunk(1, of: "a.txt", under: .staged, in: work), in: work.path)
        try await work.session.unstage(try await hunk(0, of: "a.txt", under: .staged, in: work), in: work.path)
        #expect(try await work.short() == [" M a.txt"])
        #expect(try await staged("a.txt", in: work) == Self.numbers)
    }

    /// The index is the diff's old side, so the hunk keeps the old side's line
    /// numbers. With the new side's, git would look first at the second copy of
    /// the same lines, 8 lines further down, where the hunk above added 8 lines.
    @Test func stagesTheHunkAskedForWhenAnotherCopyOfItsLinesIsWhereTheNewSideSays() async throws {
        let work = try await work()
        let lines = { (middle: String) in "same\nsame\nsame\n\(middle)\nsame\nsame\nsame\n" }
        let rest = (2...20).map { "\($0)\n" }.joined()
        let added = String(repeating: "new\n", count: 8)
        let original = "1\n" + rest + lines("x") + "gap\n" + lines("x") + "tail\n"
        try work.write(original, to: "c.txt")
        try await runGit("add", "c.txt", in: work.path)
        try await runGit("commit", "--quiet", "--message=More", in: work.path)

        let changed = "1\n" + added + rest + lines("changed") + "gap\n" + lines("changed") + "tail\n"
        try work.write(changed, to: "c.txt")
        try await work.session.stage(try await hunk(1, of: "c.txt", under: .unstaged, in: work), in: work.path)
        #expect(try await staged("c.txt", in: work) == "1\n" + rest + lines("changed") + "gap\n" + lines("x") + "tail\n")
        #expect(try work.read("c.txt") == changed)
    }

    @Test func refusesToStageAHunkWhenTheIndexHasChangedUnderIt() async throws {
        let work = try await work()
        try work.write(numbers(replacing: [30: "thirty"]), to: "a.txt")
        let hunk = try await hunk(0, of: "a.txt", under: .unstaged, in: work)
        // Something else stages the file while the diff is on screen.
        try await runGit("add", "a.txt", in: work.path)
        await #expect(throws: GitError.self) {
            try await work.session.stage(hunk, in: work.path)
        }
        #expect(try await staged("a.txt", in: work) == numbers(replacing: [30: "thirty"]))
    }

    @Test func stagesAHunkOfAFileWithSpacesInItsName() async throws {
        let work = try await work(files: ["with space čćž.txt": Self.numbers])
        try work.write(numbers(replacing: [3: "three"]), to: "with space čćž.txt")
        try await work.session.stage(try await hunk(0, of: "with space čćž.txt", under: .unstaged, in: work), in: work.path)
        #expect(try await staged("with space čćž.txt", in: work) == numbers(replacing: [3: "three"]))
    }
}
