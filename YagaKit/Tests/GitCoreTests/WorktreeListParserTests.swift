import Testing
@testable import GitCore

struct WorktreeListParserTests {
    let commit = "777f0408934b3f01eddf7d691a8568e2c0d459e1"

    /// What git prints, with each field on its own line and an empty line
    /// after each worktree, turned into NUL bytes.
    func output(_ lines: [String]) -> [UInt8] {
        Array(lines.map { $0 + "\0" }.joined().utf8)
    }

    @Test func readsEveryKindOfWorktree() throws {
        let worktrees = try WorktreeListParser.parse(output([
            "worktree /work/main", "HEAD \(commit)", "branch refs/heads/main", "",
            "worktree /work/detached", "HEAD \(commit)", "detached", "",
            "worktree /work/gone", "HEAD \(commit)", "branch refs/heads/gone",
            "prunable gitdir file points to non-existent location", "",
            "worktree /work/locked", "HEAD \(commit)", "branch refs/heads/locked", "locked on a USB drive", "",
        ]))
        let head = try #require(ObjectID(hex: commit))
        #expect(worktrees == [
            Worktree(path: "/work/main", head: head, branch: "refs/heads/main", isMain: true),
            Worktree(path: "/work/detached", head: head),
            Worktree(path: "/work/gone", head: head, branch: "refs/heads/gone", isPrunable: true),
            Worktree(path: "/work/locked", head: head, branch: "refs/heads/locked"),
        ])
    }

    @Test func readsABranchWithoutCommits() throws {
        let worktrees = try WorktreeListParser.parse(output([
            "worktree /work/new", "HEAD " + String(repeating: "0", count: 40), "branch refs/heads/main", "",
        ]))
        #expect(worktrees == [Worktree(path: "/work/new", branch: "refs/heads/main", isMain: true)])
    }

    @Test func readsABareRepository() throws {
        let worktrees = try WorktreeListParser.parse(output([
            "worktree /work/yaga.git", "bare", "",
            "worktree /work/feature", "HEAD \(commit)", "branch refs/heads/feature", "",
        ]))
        #expect(worktrees.map(\.isBare) == [true, false])
        #expect(worktrees.map(\.isMain) == [true, false])
        #expect(worktrees[0].head == nil)
    }

    @Test func readsPathsWithAnyCharacter() throws {
        let worktrees = try WorktreeListParser.parse(output(["worktree /work/two words/new\nline", "detached", ""]))
        #expect(worktrees.map(\.path) == ["/work/two words/new\nline"])
    }

    @Test func readsNothing() throws {
        #expect(try WorktreeListParser.parse([]).isEmpty)
    }

    @Test(arguments: [
        ["HEAD 777f0408934b3f01eddf7d691a8568e2c0d459e1", ""],
        ["worktree", ""],
        ["worktree /work/main", "HEAD main", ""],
        ["worktree /work/main", "HEAD 777f0408934b3f01eddf7d691a8568e2c0d459e1"],
    ])
    func rejectsOtherOutput(lines: [String]) {
        #expect(throws: ParseError.self) {
            try WorktreeListParser.parse(output(lines))
        }
    }

    @Test func rejectsAFieldWithoutItsEnd() {
        #expect(throws: ParseError.self) {
            try WorktreeListParser.parse(Array("worktree /work/main\0detached".utf8))
        }
    }
}
