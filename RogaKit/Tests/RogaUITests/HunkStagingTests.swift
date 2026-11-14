import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

/// Staging and unstaging one hunk from the diff panel, with the discarding tests'
/// worktrees.
extension DiscardTests {
    func staged(_ file: String, in work: Worktree) async throws -> String {
        // `text` would drop the file's last newline.
        try await TestGit.make().run(GitCommand("show", ":" + file, in: work.path)).text
    }

    @Test func stagingAHunkLeavesTheFileAndItsOtherHunk() async throws {
        let work = try await worktree()
        let changed = numbers(replacing: [3: "three", 30: "thirty"])
        try work.write(changed, to: "a.txt")
        await work.open()
        let headers = try work.hunkHeaders()
        #expect(headers.count == 2)
        #expect(work.changes.hunkStage != nil)
        #expect(work.changes.hunkUnstage == nil)

        work.changes.stageHunk(at: headers[1])
        await work.settled()
        #expect(work.branch.failure == nil)
        #expect(try await staged("a.txt", in: work) == numbers(replacing: [30: "thirty"]))
        #expect(try work.read("a.txt") == changed)
        #expect(work.selectedFile.file?.path == "a.txt")
        #expect(try work.hunkHeaders().count == 1)
        #expect(work.staged.map(\.path) == ["a.txt"])
        #expect(work.unstaged.map(\.path) == ["a.txt"])
    }

    @Test func theLastHunkStagedTakesTheFileOffUnstaged() async throws {
        let work = try await worktree()
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        try work.write("changed\n", to: "b.txt")
        await work.open()
        #expect(work.selectedFile.file?.path == "a.txt")
        work.changes.stageHunk(at: try work.hunkHeaders()[0])
        // The next file takes its place, as it does for a file staged from its row.
        #expect(work.selectedFile.file?.path == "b.txt")
        await work.settled()
        #expect(work.unstaged.map(\.path) == ["b.txt"])
        #expect(work.staged.map(\.path) == ["a.txt"])
    }

    @Test func unstagingAHunkLeavesTheFileAndItsOtherHunk() async throws {
        let work = try await worktree()
        let changed = numbers(replacing: [3: "three", 30: "thirty"])
        try work.write(changed, to: "a.txt")
        try await work.git("add", "a.txt")
        await work.open()
        work.changes.select(try #require(work.staged.first { $0.path == "a.txt" }), in: .staged)
        await work.settled()
        #expect(work.changes.hunkUnstage != nil)
        #expect(work.changes.hunkStage == nil)
        #expect(work.changes.hunkDiscard == nil)

        work.changes.unstageHunk(at: try work.hunkHeaders()[0])
        await work.settled()
        #expect(work.branch.failure == nil)
        #expect(try await staged("a.txt", in: work) == numbers(replacing: [30: "thirty"]))
        #expect(try work.read("a.txt") == changed)
        #expect(try work.hunkHeaders().count == 1)
    }

    @Test func theSameHunkCantBeStagedTwiceBeforeTheNewPatchIsRead() async throws {
        let work = try await worktree()
        try work.write(numbers(replacing: [3: "three", 30: "thirty"]), to: "a.txt")
        await work.open()
        let headers = try work.hunkHeaders()
        work.changes.stageHunk(at: headers[0])
        work.changes.stageHunk(at: headers[0])
        work.changes.stageHunk(at: headers[1])
        await work.settled()
        #expect(work.branch.failure == nil)
        #expect(try await staged("a.txt", in: work) == numbers(replacing: [3: "three"]))
    }

    @Test func aHunkThatCantBeStagedSaysSoAndChangesNothing() async throws {
        let work = try await worktree()
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        await work.open()
        let header = try work.hunkHeaders()[0]
        // Something else stages the file while the diff is on screen.
        try await work.git("add", "a.txt")
        work.changes.stageHunk(at: header)
        await work.settled()
        #expect(work.branch.failure?.title == "Can't stage the hunk of a.txt")
        #expect(try await staged("a.txt", in: work) == numbers(replacing: [3: "three"]))
    }
}
