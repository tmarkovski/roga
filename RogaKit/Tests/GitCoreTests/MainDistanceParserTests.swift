import GitCore
import Testing

/// Finding the main branch on the remote, and reading which files a merge of
/// it would conflict in (decision 119).
struct MainDistanceParserTests {
    func lines(_ lines: [String]) -> [UInt8] {
        Array(lines.map { $0.replacing("|", with: "\0") + "\n" }.joined().utf8)
    }

    @Test func prefersTheBranchOriginsHeadNames() throws {
        let output = lines([
            "refs/heads/main||refs/remotes/origin/main",
            "refs/remotes/fork/HEAD|refs/remotes/fork/dev|",
            "refs/remotes/origin/HEAD|refs/remotes/origin/trunk|",
        ])
        let main = try #require(try MainBranchParser.parse(output))
        #expect(main.base == "refs/remotes/origin/trunk")
        #expect(main.local == "refs/heads/trunk")
    }

    @Test func takesAnotherRemotesHeadWithoutOrigins() throws {
        let main = try #require(try MainBranchParser.parse(lines(["refs/remotes/fork/HEAD|refs/remotes/fork/dev|"])))
        #expect(main.base == "refs/remotes/fork/dev")
        #expect(main.local == "refs/heads/dev")
    }

    @Test func withoutARemotesHeadComparesThroughMainsUpstream() throws {
        let main = try #require(try MainBranchParser.parse(lines(["refs/heads/main||refs/remotes/origin/main"])))
        #expect(main.base == "refs/remotes/origin/main")
        #expect(main.local == "refs/heads/main")
    }

    @Test func aMainWithoutAnUpstreamIsComparedAsItIs() throws {
        let main = try #require(try MainBranchParser.parse(lines(["refs/heads/master||"])))
        #expect(main.base == "refs/heads/master")
    }

    @Test func prefersMainToMaster() throws {
        let main = try #require(try MainBranchParser.parse(lines(["refs/heads/main||", "refs/heads/master||"])))
        #expect(main.local == "refs/heads/main")
    }

    @Test func nothingListedIsNoMainBranch() throws {
        #expect(try MainBranchParser.parse([]) == nil)
    }

    @Test func aLineWithTheWrongFieldsIsAnError() {
        #expect(throws: ParseError.self) { try MainBranchParser.parse(lines(["refs/heads/main"])) }
    }

    @Test func readsTheFilesAfterTheTree() throws {
        let tree = String(repeating: "a", count: 40)
        let output = Array("\(tree)\0src/a.swift\0b c.txt\0".utf8)
        #expect(try MergeTreeParser.conflicts(in: output) == ["src/a.swift", "b c.txt"])
        #expect(try MergeTreeParser.conflicts(in: Array("\(tree)\0".utf8)) == [])
    }

    @Test func outputWithoutATreeIsAnError() {
        #expect(throws: ParseError.self) { try MergeTreeParser.conflicts(in: Array("fatal\0".utf8)) }
    }
}
