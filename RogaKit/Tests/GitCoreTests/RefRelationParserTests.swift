import Testing
@testable import GitCore

struct RefRelationParserTests {
    func line(_ fields: String...) -> [UInt8] {
        Array((fields.joined(separator: "\0") + "\n").utf8)
    }

    @Test func readsHowARefStandsAgainstHeadAndItsUpstream() throws {
        let output = line("refs/heads/fix", "3 1", "refs/remotes/origin/tm/fix", "ahead 2, behind 4", "origin", "refs/heads/tm/fix", "fork")
        #expect(try RefRelationParser.parse(output) == [
            "refs/heads/fix": RefRelation(
                ahead: 3,
                behind: 1,
                upstream: .init(name: "refs/remotes/origin/tm/fix", ahead: 2, behind: 4, remote: "origin", branchOnRemote: "tm/fix"),
                pushRemote: "fork"
            ),
        ])
    }

    @Test func aRefWithoutAnUpstreamOrWhoseUpstreamIsGoneHasNone() throws {
        let output = line("refs/heads/a", "0 0", "", "", "", "", "") + line("refs/heads/b", "1 0", "refs/remotes/origin/b", "gone", "origin", "refs/heads/b", "")
        let relations = try RefRelationParser.parse(output)
        #expect(relations["refs/heads/a"] == RefRelation(ahead: 0, behind: 0))
        #expect(relations["refs/heads/b"] == RefRelation(ahead: 1, behind: 0))
    }

    @Test func refusesAnythingElse() {
        #expect(throws: ParseError.self) { try RefRelationParser.parse(line("refs/heads/a", "many", "", "", "", "", "")) }
        #expect(throws: ParseError.self) { try RefRelationParser.parse(line("refs/heads/a", "1 2")) }
    }

    @Test func aBranchUsesTheRemoteItTracksOrElseTheOneItWillPushTo() {
        let tracked = RefRelation.Upstream(name: "refs/remotes/origin/a", remote: "origin")
        #expect(RefRelation(ahead: 0, behind: 0, upstream: tracked, pushRemote: "fork").remote == "origin")
        #expect(RefRelation(ahead: 0, behind: 0, pushRemote: "fork").remote == "fork")
        #expect(RefRelation(ahead: 0, behind: 0).remote == nil)
    }

    @Test func choosingARemoteThatHasTheBranchTracksItThere() {
        let origin = RefRelation.Upstream(name: "refs/remotes/origin/fix", remote: "origin", branchOnRemote: "fix")
        let choice = UpstreamChoice(branch: "fix", remote: "fork", upstream: origin) { $0 == "refs/remotes/fork/fix" }
        #expect(choice.commands == [
            ["branch", "--set-upstream-to=refs/remotes/fork/fix", "fix"],
            ["config", "branch.fix.pushRemote", "fork"],
        ])
    }

    @Test func aBranchKeepsTheNameItTracksWhenTheNewRemoteHasThat() {
        let origin = RefRelation.Upstream(name: "refs/remotes/origin/tm/fix", remote: "origin", branchOnRemote: "tm/fix")
        let choice = UpstreamChoice(branch: "fix", remote: "fork", upstream: origin) { _ in true }
        #expect(choice.branchOnRemote == "tm/fix")
        let onlyOwnName = UpstreamChoice(branch: "fix", remote: "fork", upstream: origin) { $0 == "refs/remotes/fork/fix" }
        #expect(onlyOwnName.branchOnRemote == "fix")
    }

    @Test func choosingARemoteThatHasntGotTheBranchWaitsForItsFirstPush() {
        let origin = RefRelation.Upstream(name: "refs/remotes/origin/fix", remote: "origin", branchOnRemote: "fix")
        let tracking = UpstreamChoice(branch: "fix", remote: "fork", upstream: origin) { _ in false }
        #expect(tracking.commands == [["branch", "--unset-upstream", "fix"], ["config", "branch.fix.pushRemote", "fork"]])
        let new = UpstreamChoice(branch: "fix", remote: "fork", upstream: nil) { _ in false }
        #expect(new.commands == [["config", "branch.fix.pushRemote", "fork"]])
    }

    @Test func aRemoteAddsOneCommandForItsPushURLOnlyIfThatsDifferent() {
        #expect(NewRemote(name: "fork", url: "a").commands == [["remote", "add", "fork", "a"]])
        #expect(NewRemote(name: "fork", url: "a", pushURL: "").commands == [["remote", "add", "fork", "a"]])
        #expect(NewRemote(name: "fork", url: "a", pushURL: "a").commands == [["remote", "add", "fork", "a"]])
        #expect(NewRemote(name: "fork", url: "a", pushURL: "b").commands == [
            ["remote", "add", "fork", "a"],
            ["remote", "set-url", "--push", "fork", "b"],
        ])
    }

    @Test func aRemoteNeedsANameAndAURLGitWontMistakeForAnOption() {
        let remotes = ["origin"]
        #expect(NewRemote(name: "fork", url: "a").canBeAdded(among: remotes))
        #expect(!NewRemote(name: "", url: "a").canBeAdded(among: remotes))
        #expect(!NewRemote(name: "fork", url: "").canBeAdded(among: remotes))
        #expect(NewRemote(name: "origin", url: "a").problem(among: remotes) == .nameTaken)
        #expect(NewRemote(name: "a b", url: "a").problem(among: remotes) == .badName)
        #expect(NewRemote(name: "-x", url: "a").problem(among: remotes) == .badName)
        #expect(NewRemote(name: "fork", url: "--upload-pack=x").problem(among: remotes) == .badURL)
        #expect(NewRemote(name: "fork", url: "a", pushURL: "-x").problem(among: remotes) == .badURL)
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
