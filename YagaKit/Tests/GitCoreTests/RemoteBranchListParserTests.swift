import Testing
@testable import GitCore

struct RemoteBranchListParserTests {
    func output(_ lines: [(String, String)]) -> [UInt8] {
        Array(lines.map { $0.0 + "\0" + $0.1 + "\n" }.joined().utf8)
    }

    @Test func readsWhatEachBranchTracks() throws {
        let branches = try RemoteBranchListParser.parse(output([
            ("refs/heads/fix/login", "refs/remotes/origin/login"),
            ("refs/heads/main", "refs/remotes/origin/main"),
            ("refs/heads/unpushed", ""),
            ("refs/remotes/origin/HEAD", ""),
            ("refs/remotes/origin/login", ""),
            ("refs/remotes/origin/main", ""),
        ]))
        #expect(branches == ["refs/heads/fix/login": "refs/remotes/origin/login", "refs/heads/main": "refs/remotes/origin/main"])
    }

    @Test func leavesOutAnUpstreamThatsGone() throws {
        let branches = try RemoteBranchListParser.parse(output([("refs/heads/merged", "refs/remotes/origin/merged")]))
        #expect(branches.isEmpty)
    }

    @Test func leavesOutAnotherLocalBranch() throws {
        let branches = try RemoteBranchListParser.parse(output([("refs/heads/main", ""), ("refs/heads/topic", "refs/heads/main")]))
        #expect(branches.isEmpty)
    }

    @Test func readsNothing() throws {
        #expect(try RemoteBranchListParser.parse([]).isEmpty)
    }

    @Test func refusesALineWithTheWrongFields() {
        #expect(throws: ParseError.self) {
            try RemoteBranchListParser.parse(Array("refs/heads/main\n".utf8))
        }
    }
}
