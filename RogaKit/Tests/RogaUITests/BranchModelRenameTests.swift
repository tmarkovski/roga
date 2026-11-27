import Foundation
import GitCore
import RepositoryEngine
import Testing
@testable import RogaUI

/// Renaming the worktree's branch from the popover about the checkout, here
/// and nowhere else, and pushing it afterwards (decision 120).
extension BranchModelTests {
    /// The work clone on `agent/fix`, pushed, so that it tracks
    /// `origin/agent/fix`, and a model that has looked at it.
    func pushedBranchModel(_ clones: Clones) async throws -> RepositoryModel {
        try await git("switch", "--quiet", "--create", "agent/fix", in: clones.work)
        try await commit("One", in: clones.work, file: "one.txt", text: "1\n")
        try await git("push", "--quiet", "--set-upstream", "origin", "HEAD", in: clones.work)
        return try await measuredModel(clones)
    }

    @Test func renamingSaysTheBranchKeepsItsUpstream() async throws {
        let clones = try await clones()
        let model = try await pushedBranchModel(clones)
        #expect(model.branch.renameNote == "It keeps tracking origin/agent/fix, which keeps its name, and ↑ pushes to it by that name.")
    }

    @Test func aRenamedBranchPushesToItsUpstreamByName() async throws {
        let clones = try await clones()
        let model = try await pushedBranchModel(clones)
        #expect(await model.branch.rename(to: "fix-login") == nil)
        try await commit("Two", in: clones.work, file: "two.txt", text: "2\n")
        await model.branch.refresh()
        await model.branch.measuring?.value
        #expect(model.branch.status?.branch == "refs/heads/fix-login")
        #expect(model.branch.status?.upstream == "refs/remotes/origin/agent/fix")
        #expect(model.branch.pushToRun == .otherBranch("fix-login", remote: "origin", onRemote: "agent/fix"))
        #expect(model.branch.pushHelp.hasSuffix("git push origin fix-login:agent/fix"))
        #expect(model.branch.undoFinished?.help == "Rename It Back to agent/fix")
    }

    @Test func aBranchTrackingMainKeepsThePlainPush() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "feature", "--track", "origin/main", in: clones.work)
        try await commit("One", in: clones.work, file: "one.txt", text: "1\n")
        let model = try await measuredModel(clones)
        #expect(model.branch.renameNote == "It keeps tracking origin/main.")
        #expect(model.branch.pushToRun == .toUpstream)
    }

    @Test func aNameAnotherBranchHasIsRefusedAndNothingChanges() async throws {
        let clones = try await clones()
        let model = try await pushedBranchModel(clones)
        let refusal = try #require(await model.branch.rename(to: "main"))
        #expect(refusal.contains("already exists"))
        await model.branch.refresh()
        #expect(model.branch.status?.branch == "refs/heads/agent/fix")
        #expect(await model.branch.rename(to: "-d") == "A branch's name can't start with a hyphen.")
    }

    @Test func aBranchThatWasNeverPushedSaysNothingAboutAnUpstream() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "agent/new", in: clones.work)
        try await commit("One", in: clones.work, file: "one.txt", text: "1\n")
        let model = try await measuredModel(clones)
        #expect(model.branch.renameNote == nil)
        #expect(await model.branch.rename(to: "new-idea") == nil)
        await model.branch.refresh()
        #expect(model.branch.status?.branch == "refs/heads/new-idea")
        #expect(model.branch.status?.upstream == nil)
    }
}
