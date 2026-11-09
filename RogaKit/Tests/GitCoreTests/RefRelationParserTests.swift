import Testing
@testable import GitCore

struct RefRelationParserTests {
    func line(_ fields: String...) -> [UInt8] {
        Array((fields.joined(separator: "\0") + "\n").utf8)
    }

    @Test func readsHowARefStandsAgainstHeadAndItsUpstream() throws {
        let output = line("refs/heads/fix", "3 1", "refs/remotes/origin/tm/fix", "ahead 2, behind 4", "origin", "refs/heads/tm/fix")
        #expect(try RefRelationParser.parse(output) == [
            "refs/heads/fix": RefRelation(
                ahead: 3,
                behind: 1,
                upstream: .init(name: "refs/remotes/origin/tm/fix", ahead: 2, behind: 4, remote: "origin", branchOnRemote: "tm/fix")
            ),
        ])
    }

    @Test func aRefWithoutAnUpstreamOrWhoseUpstreamIsGoneHasNone() throws {
        let output = line("refs/heads/a", "0 0", "", "", "", "") + line("refs/heads/b", "1 0", "refs/remotes/origin/b", "gone", "origin", "refs/heads/b")
        let relations = try RefRelationParser.parse(output)
        #expect(relations["refs/heads/a"] == RefRelation(ahead: 0, behind: 0))
        #expect(relations["refs/heads/b"] == RefRelation(ahead: 1, behind: 0))
    }

    @Test func refusesAnythingElse() {
        #expect(throws: ParseError.self) { try RefRelationParser.parse(line("refs/heads/a", "many", "", "", "", "")) }
        #expect(throws: ParseError.self) { try RefRelationParser.parse(line("refs/heads/a", "1 2")) }
    }

    @Test func asksAboutTheCommitByItsID() {
        let id = ObjectID(hex: String(repeating: "a", count: 40))!
        #expect(RefRelationParser.format(comparingWith: id).contains("%(ahead-behind:\(id.hex))"))
    }

    @Test func aNewBranchOrTagCanStartAtAnyCommit() {
        let id = ObjectID(hex: String(repeating: "a", count: 40))!
        #expect(NewBranch(name: "x", startPoint: id).arguments == ["switch", "-c", "x", id.hex])
        #expect(NewBranch(name: "x/y", inNewWorktree: true, startPoint: id).arguments == ["worktree", "add", "-b", "x/y", "../x-y", id.hex])
        #expect(NewBranch(name: "x").arguments == ["switch", "-c", "x"])
        #expect(NewTag(name: "v1", commit: id).arguments == ["tag", "v1", id.hex])
    }

    @Test func aBranchThatIsntCheckedOutIsPushedByItsName() {
        #expect(Push.otherBranch("fix", remote: "origin", onRemote: nil).arguments == ["push", "origin", "fix"])
        #expect(Push.otherBranch("fix", remote: "origin", onRemote: "tm/fix").arguments == ["push", "origin", "fix:tm/fix"])
        #expect(Push.otherBranchFirstTime("fix", remote: "origin").arguments == ["push", "--set-upstream", "origin", "fix"])
    }
}
