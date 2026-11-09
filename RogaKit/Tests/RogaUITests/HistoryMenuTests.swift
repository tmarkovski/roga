import GitCore
import MenuUI
import Testing
@testable import RogaUI

/// Which rows right-clicking offers, for each kind of thing that can be clicked
/// (decision 65).
@Suite
struct HistoryMenuTests {
    let commit = ObjectID(hex: String(repeating: "1", count: 40))!
    let head = ObjectID(hex: String(repeating: "2", count: 40))!
    let main = "refs/heads/main"
    let feature = "refs/heads/feature"

    /// The rows' titles. A submenu has a `▸` after its title, and a line is `-`.
    func titles(_ entries: [RefMenu.Entry]) -> [String] {
        entries.map { entry in
            switch entry {
            case let .header(title): "# " + title.plain
            case let .command(title, _, _, _, _): title.plain
            case let .option(title, _, _): title.plain
            case let .choice(choice): choice.title
            case let .submenu(title, _, _, _): title.plain + " ▸"
            case .divider: "-"
            }
        }
    }

    func submenu(_ title: String, in entries: [RefMenu.Entry]) -> [RefMenu.Entry]? {
        for case let .submenu(name, _, _, inner) in entries where name.plain == title { return inner }
        return nil
    }

    func isEnabled(_ title: String, in entries: [RefMenu.Entry]) -> Bool? {
        for case let .command(name, _, enabled, _, _) in entries where name.plain == title { return enabled }
        return nil
    }

    // MARK: Set upstream

    func upstreamRow(_ entries: [RefMenu.Entry]) -> (value: String?, isEnabled: Bool, inner: [RefMenu.Entry])? {
        for case let .submenu(name, value, enabled, inner) in entries where name.plain == "Set upstream" { return (value, enabled, inner) }
        return nil
    }

    func upstream(on remote: String) -> RefRelation.Upstream {
        .init(name: "refs/remotes/\(remote)/feature", remote: remote, branchOnRemote: "feature")
    }

    @Test func aBranchChoosesFromTheRemotesAndSaysWhichItUses() throws {
        var situation = situation
        situation.remotes = ["fork", "origin"]
        situation.relation = RefRelation(ahead: 1, behind: 1, upstream: upstream(on: "origin"))
        var chosen: [String] = []
        var actions = HistoryMenu.Actions()
        actions.setUpstream = { chosen.append($0) }
        let row = try #require(upstreamRow(HistoryMenu.entries(for: target(ref: feature), in: situation, actions: actions)))
        #expect(row.value == "origin")
        #expect(titles(row.inner) == ["fork", "origin"])
        for case let .option(title, isChecked, action) in row.inner {
            #expect(isChecked == (title.plain == "origin"))
            action()
        }
        #expect(chosen == ["fork", "origin"])
    }

    @Test func theCurrentBranchHasTheRowWithItsPullAndPush() throws {
        var situation = situation
        situation.status = BranchStatus(branch: main, remote: "origin", pushRemote: "origin")
        situation.remotes = ["fork", "origin"]
        situation.relation = RefRelation(ahead: 0, behind: 0)
        let rows = titles(entries(target(ref: main), situation))
        #expect(Array(rows.prefix(5)) == ["# main", "Pull", "Push", "Fetch", "Set upstream ▸"])
    }

    @Test func aBranchThatIsntSetUpYetSaysSoOrWhereItsFirstPushGoes() throws {
        var situation = situation
        situation.remotes = ["fork", "origin"]
        situation.relation = RefRelation(ahead: 1, behind: 0)
        #expect(upstreamRow(entries(target(ref: feature), situation))?.value == "None")
        situation.relation = RefRelation(ahead: 1, behind: 0, pushRemote: "fork")
        #expect(upstreamRow(entries(target(ref: feature), situation))?.value == "fork")
    }

    @Test func thereIsNoChoiceWithOneRemoteOrForWhatIsntALocalBranch() {
        var situation = situation
        situation.relation = RefRelation(ahead: 1, behind: 0)
        situation.remotes = ["origin"]
        #expect(upstreamRow(entries(target(ref: feature), situation)) == nil)
        situation.remotes = ["fork", "origin"]
        #expect(upstreamRow(entries(target(ref: "refs/remotes/origin/feature"), situation)) == nil)
        #expect(upstreamRow(entries(target(ref: "refs/tags/v1"), situation)) == nil)
        #expect(upstreamRow(entries(target(), situation)) == nil)
    }

    @Test func aBranchNameInARowCarriesTheBranchIcon() throws {
        var situation = situation
        situation.relation = RefRelation(ahead: 1, behind: 1)
        let all = entries(target(ref: feature), situation)
        guard case let .header(heading) = try #require(all.first) else { throw TestFailure() }
        #expect(heading.parts == [.branch("feature")])
        let merge = try #require(all.compactMap { entry -> RefMenu.Title? in
            if case let .command(title, _, _, _, _) = entry, title.plain.hasPrefix("Merge") { title } else { nil }
        }.first)
        #expect(merge.parts == [.text("Merge "), .branch("feature"), .text(" into "), .branch("main"), .text("…")])
    }

    @Test func hEADIsntABranchSoItHasNoIcon() throws {
        var situation = situation
        situation.currentBranch = nil
        let all = entries(target(), situation)
        let pick = try #require(all.compactMap { entry -> RefMenu.Title? in
            if case let .command(title, _, _, _, _) = entry, title.plain.hasPrefix("Cherry") { title } else { nil }
        }.first)
        #expect(pick.plain == "Cherry-pick into HEAD")
        #expect(!pick.parts.contains { if case .branch = $0 { true } else { false } })
    }

    struct TestFailure: Error {}

    var situation: HistoryMenu.Situation {
        HistoryMenu.Situation(currentBranch: main, head: head)
    }

    func target(ref: String? = nil, commit: ObjectID? = nil) -> HistoryMenu.Target {
        HistoryMenu.Target(commit: commit ?? self.commit, shortID: "11111111", subject: "A subject", ref: ref)
    }

    func entries(_ target: HistoryMenu.Target, _ situation: HistoryMenu.Situation, actions: HistoryMenu.Actions = HistoryMenu.Actions()) -> [RefMenu.Entry] {
        HistoryMenu.entries(for: target, in: situation, actions: actions)
    }

    // MARK: A branch that isn't checked out

    @Test func anotherBranchThatHasMovedApartCanBeMergedOrRebased() {
        var situation = situation
        situation.relation = RefRelation(ahead: 2, behind: 3)
        situation.headContains = false
        #expect(titles(entries(target(ref: feature), situation)) == [
            "# feature",
            "Check out",
            "Merge feature into main…",
            "Rebase main onto feature…",
            "Cherry-pick into main",
            "-",
            "Reset main to here…",
            "Revert…",
            "-",
            "Create ▸",
            "Copy ▸",
        ])
    }

    @Test func aBranchAheadOfHeadOffersAFastForwardInstead() {
        var situation = situation
        situation.relation = RefRelation(ahead: 2, behind: 0)
        let rows = titles(entries(target(ref: feature), situation))
        #expect(rows.contains("Fast-forward main to feature"))
        #expect(!rows.contains { $0.hasPrefix("Merge") || $0.hasPrefix("Rebase") })
    }

    @Test func aBranchHeadAlreadyHasHasNothingToBringIn() {
        var situation = situation
        situation.relation = RefRelation(ahead: 0, behind: 4)
        situation.headContains = true
        let rows = titles(entries(target(ref: feature), situation))
        #expect(!rows.contains { $0.hasPrefix("Merge") || $0.hasPrefix("Rebase") || $0.hasPrefix("Fast-forward") || $0.hasPrefix("Cherry-Pick") })
        #expect(rows.contains("Reset main to here…"))
    }

    @Test func untilTheRelationIsReadItOffersBothWays() {
        let rows = titles(entries(target(ref: feature), situation))
        #expect(rows.contains("Merge feature into main…"))
        #expect(rows.contains("Rebase main onto feature…"))
    }

    @Test func aRemoteCopyOfTheCurrentBranchHasNothingToCheckOut() {
        var situation = situation
        situation.isRemoteCopyOfCurrentBranch = true
        situation.relation = RefRelation(ahead: 1, behind: 0)
        let rows = titles(entries(target(ref: "refs/remotes/origin/main"), situation))
        #expect(rows[0] == "# origin/main")
        #expect(!rows.contains("Check out"))
        #expect(rows.contains("Fast-forward main to origin/main"))
    }

    @Test func aBranchInAnotherWorktreeGoesThere() {
        var actions = HistoryMenu.Actions()
        actions.showOtherWorktree = {}
        let rows = titles(entries(target(ref: feature), situation, actions: actions))
        #expect(rows.contains("Show worktree"))
        #expect(!rows.contains("Check out"))
    }

    @Test func aBranchCanBePushedOrFastForwardedFromItsUpstream() throws {
        var situation = situation
        situation.relation = RefRelation(ahead: 1, behind: 1, upstream: .init(name: "refs/remotes/origin/feature", ahead: 0, behind: 2))
        var actions = HistoryMenu.Actions()
        actions.pushBranch = {}
        let all = entries(target(ref: feature), situation, actions: actions)
        let remote = try #require(submenu("Remote", in: all))
        #expect(titles(remote) == ["Push feature", "Fast-forward from origin/feature"])
        // It's behind, so git would reject a push.
        #expect(isEnabled("Push feature", in: remote) == false)
        #expect(isEnabled("Fast-forward from origin/feature", in: remote) == true)
    }

    @Test func aRemoteBranchHasNothingToPush() {
        var situation = situation
        situation.relation = RefRelation(ahead: 1, behind: 1)
        var actions = HistoryMenu.Actions()
        actions.pushBranch = {}
        #expect(submenu("Remote", in: entries(target(ref: "refs/remotes/origin/feature"), situation, actions: actions)) == nil)
    }

    // MARK: The current branch

    @Test func theCurrentBranchHasPullPushAndFetch() {
        var situation = situation
        situation.status = BranchStatus(branch: main, upstream: "refs/remotes/origin/main", ahead: 1, behind: 0, remote: "origin")
        let all = entries(target(ref: main, commit: head), situation)
        #expect(titles(all) == ["# main", "Pull", "Push", "Fetch", "-", "Create ▸", "Copy ▸"])
        #expect(isEnabled("Pull", in: all) == false)
        #expect(isEnabled("Push", in: all) == true)
        #expect(isEnabled("Fetch", in: all) == true)
    }

    @Test func aPullThatHasToAskSaysSo() {
        var situation = situation
        situation.status = BranchStatus(branch: main, upstream: "refs/remotes/origin/main", ahead: 1, behind: 1, remote: "origin")
        let all = entries(target(ref: main, commit: head), situation)
        #expect(isEnabled("Pull…", in: all) == true)
    }

    // MARK: A commit

    @Test func aPlainCommitCanBeGoneToAppliedResetToOrReverted() {
        var situation = situation
        situation.headContains = false
        #expect(titles(entries(target(), situation)) == [
            "# 11111111",
            "Check out this commit",
            "Cherry-pick into main",
            "-",
            "Reset main to here…",
            "Revert…",
            "-",
            "Create ▸",
            "Copy ▸",
        ])
    }

    @Test func aCommitHeadHasHasNothingToCherryPick() {
        var situation = situation
        situation.headContains = true
        #expect(!titles(entries(target(), situation)).contains("Cherry-pick into main"))
    }

    @Test func theCommitHeadIsOnHasNowhereToGo() {
        let rows = titles(entries(target(commit: head), situation))
        #expect(!rows.contains("Check out this commit"))
        #expect(!rows.contains("Reset main to here…"))
        #expect(rows.contains("Revert…"))
    }

    @Test func aDetachedHeadHasNoBranchToReset() {
        var situation = situation
        situation.currentBranch = nil
        situation.headContains = false
        let rows = titles(entries(target(), situation))
        #expect(rows.contains("Cherry-pick into HEAD"))
        #expect(!rows.contains { $0.hasPrefix("Reset") })
    }

    @Test func aTagActsOnItsCommitAndCanCopyItsName() throws {
        var situation = situation
        situation.headContains = false
        let all = entries(target(ref: "refs/tags/v1"), situation)
        #expect(titles(all).first == "# v1")
        #expect(titles(all).contains("Check out this commit"))
        #expect(!titles(all).contains { $0.hasPrefix("Merge") })
        #expect(titles(try #require(submenu("Copy", in: all))) == ["Hash", "Subject", "Tag name"])
    }

    // MARK: What's in the groups

    @Test func createOffersABranchAWorktreeAndATag() throws {
        let all = entries(target(), situation)
        #expect(titles(try #require(submenu("Create", in: all))) == ["Branch here…", "Worktree here…", "Tag here…"])
    }

    @Test func copyHasTheFullHash() throws {
        var copied: [String] = []
        var actions = HistoryMenu.Actions()
        actions.copy = { copied.append($0) }
        let all = entries(target(ref: feature), situation, actions: actions)
        let copy = try #require(submenu("Copy", in: all))
        #expect(titles(copy) == ["Hash", "Subject", "Branch name"])
        for case let .command(_, _, _, _, action) in copy { action() }
        #expect(copied == [commit.hex, "A subject", "feature"])
    }

    @Test func reviewAndReplayComeAfterTheSubmenusAndDeleteComesLast() {
        var situation = situation
        situation.reviewBase = "main"
        var actions = HistoryMenu.Actions()
        actions.replay = {}
        actions.delete = HistoryMenu.Delete(title: "Delete…", isEnabled: true) {}
        let rows = titles(entries(target(ref: feature), situation, actions: actions))
        #expect(rows.suffix(6) == ["Create ▸", "Copy ▸", "Review against main", "Replay history", "-", "Delete…"])
    }

    @Test func whatMovesHeadWaitsForWhatsRunningButCopyDoesnt() {
        var situation = situation
        situation.canChange = false
        situation.isBusy = true
        situation.headContains = false
        let all = entries(target(ref: feature), situation)
        for title in ["Check out", "Merge feature into main…", "Rebase main onto feature…", "Cherry-pick into main", "Reset main to here…", "Revert…"] {
            #expect(isEnabled(title, in: all) == false, "\(title)")
        }
        var copyIsEnabled = false
        for case let .submenu(name, _, enabled, _) in all where name.plain == "Copy" { copyIsEnabled = enabled }
        #expect(copyIsEnabled)
    }

    @Test func nothingRunsForAPartwayWorktreeButCreateStillDoes() {
        var situation = situation
        situation.canChange = false
        situation.headContains = false
        let all = entries(target(), situation)
        #expect(isEnabled("Cherry-pick into main", in: all) == false)
        var createIsEnabled = false
        for case let .submenu(name, _, enabled, _) in all where name.plain == "Create" { createIsEnabled = enabled }
        #expect(createIsEnabled)
    }
}
