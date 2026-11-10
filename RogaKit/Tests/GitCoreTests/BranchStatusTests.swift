import Testing
@testable import GitCore

struct BranchStatusTests {
    func status(ahead: Int = 0, behind: Int = 0, pullRebase: String? = nil) -> BranchStatus {
        BranchStatus(branch: "refs/heads/main", upstream: "refs/remotes/origin/main", ahead: ahead, behind: behind, remote: "origin", pushRemote: "origin", pullRebase: pullRebase)
    }

    @Test func pullsOnlyWhenTheresSomethingToPull() {
        #expect(status().pull == nil)
        #expect(status(ahead: 2).pull == nil)
    }

    @Test func fastForwardsABranchThatsOnlyBehind() {
        #expect(status(behind: 3).pull == .fastForward)
        #expect(status(behind: 3, pullRebase: "true").pull == .fastForward)
    }

    @Test func aDivergedBranchPullsAsConfiguredOrAsks() {
        #expect(status(ahead: 1, behind: 3, pullRebase: "true").pull == .configured)
        #expect(status(ahead: 1, behind: 3, pullRebase: "false").pull == .configured)
        #expect(status(ahead: 1, behind: 3).pull == nil)
    }

    @Test func pushesOnlyWhatGitWouldAccept() {
        #expect(status().push == nil)
        #expect(status(ahead: 2).push == .toUpstream)
        #expect(status(ahead: 2, behind: 1).push == nil)
        #expect(status(behind: 1).push == nil)
    }

    @Test func aBranchWithoutAnUpstreamPushesToItsRemote() {
        let status = BranchStatus(branch: "refs/heads/agent", pushRemote: "fork")
        #expect(status.push == .firstTime(remote: "fork"))
        #expect(status.push?.arguments == ["push", "--set-upstream", "fork", "HEAD"])
        #expect(BranchStatus(branch: "refs/heads/agent").push == nil)
    }

    /// By its full name, so that a branch called the same can't go instead, and
    /// with no `--tags`, so that no other tag goes along with it.
    @Test func aTagIsPushedOnItsOwnByItsFullName() {
        #expect(Push.tag("v0.0.1", remote: "origin").arguments == ["push", "origin", "refs/tags/v0.0.1"])
    }

    @Test func aTagGoesWhereTheCurrentBranchPushes() {
        #expect(Push.remote(forTagWith: "fork", among: ["fork", "origin"]) == "fork")
    }

    @Test func withHeadDetachedATagGoesToOriginOrTheOnlyRemote() {
        #expect(Push.remote(forTagWith: nil, among: ["fork", "origin"]) == "origin")
        #expect(Push.remote(forTagWith: nil, among: ["fork"]) == "fork")
        #expect(Push.remote(forTagWith: nil, among: ["fork", "upstream"]) == nil)
        #expect(Push.remote(forTagWith: nil, among: []) == nil)
    }

    @Test func aNewWorktreeGoesNextToThisOne() {
        #expect(NewBranch(name: "fix-retry").arguments == ["switch", "-c", "fix-retry"])
        #expect(NewBranch(name: "tm/fix", inNewWorktree: true).arguments == ["worktree", "add", "-b", "tm/fix", "../tm-fix"])
    }

    func line(_ fields: String...) -> [UInt8] {
        Array(fields.joined(separator: "\0").utf8) + [UInt8(ascii: "\n")]
    }

    @Test func readsABranch() throws {
        let output = line("refs/heads/main", "refs/remotes/origin/main", "ahead 1, behind 3", "origin", "origin")
        let entry = try #require(try BranchStatusParser.parse(output, branch: "refs/heads/main"))
        #expect(entry.upstream == "refs/remotes/origin/main")
        #expect(entry.counts == BranchListParser.Counts(ahead: 1, behind: 3))
        #expect(entry.trackedRemote == "origin")
        #expect(!entry.upstreamIsGone)
    }

    @Test func readsABranchWhoseUpstreamIsGone() throws {
        let output = line("refs/heads/main", "refs/remotes/origin/main", "gone", "origin", "origin")
        let entry = try #require(try BranchStatusParser.parse(output, branch: "refs/heads/main"))
        #expect(entry.upstream == nil)
        #expect(entry.upstreamIsGone)
    }

    @Test func readsABranchWithoutAnUpstream() throws {
        let output = line("refs/heads/agent", "", "", "", "origin")
        let entry = try #require(try BranchStatusParser.parse(output, branch: "refs/heads/agent"))
        #expect(entry.upstream == nil)
        #expect(entry.trackedRemote == nil)
        #expect(entry.pushRemote == "origin")
    }

    @Test func findsNothingForABranchWithoutCommits() throws {
        #expect(try BranchStatusParser.parse([], branch: "refs/heads/main") == nil)
    }
}
