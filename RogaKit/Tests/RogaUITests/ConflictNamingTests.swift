import DiffUI
import GitCore
import RepositoryEngine
import Testing
@testable import RogaUI

/// Naming a conflict's sides by where they came from (decision 60).
struct ConflictNamingTests {
    let mine = ObjectID(hex: "a17f9d3" + String(repeating: "1", count: 33))!
    let theirs = ObjectID(hex: "86b3386" + String(repeating: "2", count: 33))!

    var naming: ConflictNaming {
        ConflictNaming(
            branch: "main",
            head: mine,
            refs: [
                Ref(name: "refs/heads/main", target: mine, upstream: "refs/remotes/origin/main"),
                Ref(name: "refs/remotes/origin/HEAD", target: theirs, symbolicTarget: "refs/remotes/origin/main"),
                Ref(name: "refs/remotes/origin/main", target: theirs),
                Ref(name: "refs/heads/copy", target: theirs),
            ],
            upstream: "refs/remotes/origin/main",
            subjects: [mine: "Add a retry button", theirs: "Show the error"]
        )
    }

    @Test func aMergeNamesTheBranchAndWhatsMergedIn() {
        let sides = naming.sides(oursLabel: "HEAD", theirsLabel: "origin/main")
        #expect(sides.ours == .init(name: "main", detail: "a17f9d3 · Add a retry button", keepTitle: "Keep main's", keptTitle: "Kept main's"))
        #expect(sides.theirs.name == "origin/main")
        #expect(sides.theirs.detail == "86b3386 · Show the error")
        #expect(sides.theirs.keepTitle == "Keep origin/main's")
    }

    @Test func aPullThatMergesNamesTheUpstreamForItsHash() {
        let sides = naming.sides(oursLabel: "HEAD", theirsLabel: theirs.hex)
        #expect(sides.theirs.name == "origin/main")
        #expect(sides.theirs.detail == "86b3386 · Show the error")
    }

    @Test func aRebaseNamesWhatItsGoingOntoAndTheCommitBeingReplayed() {
        var naming = naming
        naming.branch = nil
        naming.head = theirs
        naming.work = .rebase(branch: "refs/heads/main")
        naming.onto = theirs
        let sides = naming.sides(oursLabel: "HEAD", theirsLabel: "a17f9d3 (Add a retry button)")
        #expect(sides.ours.name == "origin/main")
        #expect(sides.ours.detail == "86b3386 · Show the error")
        #expect(sides.theirs.name == "a17f9d3")
        #expect(sides.theirs.detail == "your commit being rebased · Add a retry button")
        #expect(sides.theirs.keepTitle == "Keep a17f9d3's")
    }

    @Test func aRebaseFurtherAlongSaysSo() {
        var naming = naming
        naming.work = .rebase(branch: "refs/heads/main")
        naming.onto = theirs
        naming.head = mine
        #expect(naming.sides(oursLabel: "HEAD", theirsLabel: "b0b0b0b (Next)").ours.detail == "86b3386 and the commits rebased onto it so far")
    }

    @Test func aRevertNamesTheRevert() {
        let sides = naming.sides(oursLabel: "HEAD", theirsLabel: "parent of 86b3386 (Show the error)")
        #expect(sides.theirs == .init(name: "The revert", detail: "taking out 86b3386 · Show the error", keepTitle: "Keep the Revert", keptTitle: "Kept the revert"))
        #expect(naming.sides(oursLabel: "HEAD", theirsLabel: "parent of " + theirs.hex).theirs.detail == "taking out 86b3386 · Show the error")
    }

    @Test func aStashPopNamesYourChanges() {
        let sides = naming.sides(oursLabel: "Updated upstream", theirsLabel: "Stashed changes")
        #expect(sides.ours.name == "main")
        #expect(sides.ours.detail == "as committed, a17f9d3 · Add a retry button")
        #expect(sides.theirs.keepTitle == "Keep Yours")
    }

    @Test func aCherryPickNamesTheCommit() {
        let sides = naming.sides(oursLabel: "HEAD", theirsLabel: "86b3386 (Show the error)")
        #expect(sides.theirs.name == "86b3386")
        #expect(sides.theirs.detail == "Show the error")
    }

    @Test func aDetachedHeadIsCalledHead() {
        var naming = naming
        naming.branch = nil
        #expect(naming.sides(oursLabel: "HEAD", theirsLabel: "x").ours.name == "HEAD")
    }

    @Test func asksForTheSubjectsItCanUse() {
        #expect(Set(naming.commitsToDescribe(oursLabel: "HEAD", theirsLabel: "origin/main")) == [mine, theirs])
        #expect(naming.commitsToDescribe(oursLabel: "HEAD", theirsLabel: "parent of " + theirs.hex).contains(theirs))
    }
}
