import Foundation
import GitCore
import MenuUI
import RepositoryEngine
import Testing
@testable import RogaUI

/// Renaming a local branch here and nowhere else, from the popover about the
/// checkout, the menu bar or a branch's menu, and pushing it afterwards
/// (decision 120).
extension BranchModelTests {
    /// The work clone on `agent/fix`, pushed, so that it tracks
    /// `origin/agent/fix`, and a model that has looked at it.
    func pushedBranchModel(_ clones: Clones) async throws -> RepositoryModel {
        try await git("switch", "--quiet", "--create", "agent/fix", in: clones.work)
        try await commit("One", in: clones.work, file: "one.txt", text: "1\n")
        try await git("push", "--quiet", "--set-upstream", "origin", "HEAD", in: clones.work)
        return try await measuredModel(clones)
    }

    /// Opens the popover for renaming the worktree's branch, and says what it's for.
    func startRename(_ model: RepositoryModel) throws -> BranchModel.RenameStart {
        model.branch.startRename()
        return try #require(model.branch.renameStart)
    }

    @Test func renamingSaysTheBranchKeepsItsUpstream() async throws {
        let clones = try await clones()
        let model = try await pushedBranchModel(clones)
        let start = try startRename(model)
        #expect(start == BranchModel.RenameStart(branch: "refs/heads/agent/fix", upstream: "refs/remotes/origin/agent/fix"))
        #expect(model.branch.renamePlace == nil)
        #expect(model.branch.renameNote(for: start) == "It keeps tracking origin/agent/fix, which keeps its name, and pushing it goes there by that name.")
    }

    @Test func aRenamedBranchPushesToItsUpstreamByName() async throws {
        let clones = try await clones()
        let model = try await pushedBranchModel(clones)
        #expect(await model.branch.rename(try startRename(model), to: "fix-login") == nil)
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
        #expect(model.branch.renameNote(for: try startRename(model)) == "It keeps tracking origin/main.")
        #expect(model.branch.pushToRun == .toUpstream)
    }

    @Test func aNameAnotherBranchHasIsRefusedAndNothingChanges() async throws {
        let clones = try await clones()
        let model = try await pushedBranchModel(clones)
        let start = try startRename(model)
        let refusal = try #require(await model.branch.rename(start, to: "main"))
        #expect(refusal.contains("already exists"))
        await model.branch.refresh()
        #expect(model.branch.status?.branch == "refs/heads/agent/fix")
        #expect(await model.branch.rename(start, to: "-d") == "A branch's name can't start with a hyphen.")
    }

    @Test func aBranchThatWasNeverPushedSaysNothingAboutAnUpstream() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "agent/new", in: clones.work)
        try await commit("One", in: clones.work, file: "one.txt", text: "1\n")
        let model = try await measuredModel(clones)
        let start = try startRename(model)
        #expect(model.branch.renameNote(for: start) == nil)
        #expect(await model.branch.rename(start, to: "new-idea") == nil)
        await model.branch.refresh()
        #expect(model.branch.status?.branch == "refs/heads/new-idea")
        #expect(model.branch.status?.upstream == nil)
    }

    @Test func anotherBranchIsRenamedFromItsMenu() async throws {
        let clones = try await clones()
        let model = try await pushedBranchModel(clones)
        try await git("branch", "agent/other", in: clones.work)
        let head = try await git("rev-parse", "HEAD", in: clones.work).trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = model.menuEntries(
            forBranch: "refs/heads/agent/other",
            tip: try #require(ObjectID(hex: head)),
            delete: HistoryMenu.Delete(title: "Delete branch", isEnabled: true) {},
            showWorktree: { _, _ in }
        )
        let rename = try #require(entries.lazy.compactMap { entry -> (() -> Void)? in
            if case let .command(title, _, _, _, action) = entry, title.plain == "Rename…" { action } else { nil }
        }.first)
        rename()
        let start = try #require(model.branch.renameStart)
        #expect(start.branch == "refs/heads/agent/other")
        #expect(start.upstream == nil)
        #expect(await model.branch.rename(start, to: "other") == nil)
        let branches = try await git("for-each-ref", "--format=%(refname:short)", "refs/heads/", in: clones.work)
        #expect(branches.split(separator: "\n").map(String.init) == ["agent/fix", "main", "other"])
        model.branch.closeRename()
        #expect(model.branch.renameStart == nil)
    }
}
