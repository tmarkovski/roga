import Foundation
import GitCore
import RepositoryEngine
import Testing
@testable import RogaUI

/// What the line under the branch's name and its popover say about how far the
/// branch is from the main branch on the remote (decision 119).
extension BranchModelTests {
    /// A model of the work clone once it has looked, and worked out how far
    /// its branch is from `origin/main`.
    func measuredModel(_ clones: Clones) async throws -> RepositoryModel {
        let model = model(clones, fetches: false)
        await model.appear()
        await model.check?.value
        await model.branch.measuring?.value
        return model
    }

    @Test func theMainBranchSaysItsUpstreamUnderItsName() async throws {
        let clones = try await clones()
        let model = try await measuredModel(clones)
        #expect(model.branch.mainDistance == nil)
        #expect(!model.branch.comparesWithMain)
        #expect(model.branch.mainLine().words == model.branch.summary())
        #expect(model.branch.mainLine().words.hasPrefix("origin/main · up to date"))
        #expect(model.branch.mainDetail() == nil)
    }

    @Test func aBranchSaysHowFarItIsFromTheRemotesMain() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "agent/fix", in: clones.work)
        try await commit("One", in: clones.work, file: "one.txt", text: "1\n")
        try await commit("Two", in: clones.work, file: "two.txt", text: "2\n")
        for index in 0..<3 {
            try await pushFromOther(clones, file: "main\(index).txt", text: "\(index)\n")
        }
        try await git("fetch", "--quiet", in: clones.work)
        let model = try await measuredModel(clones)
        #expect(model.branch.mainLine().words == "2 ahead, 3 behind origin/main · not pushed yet")
        #expect(model.branch.mainLine().conflicts == nil)
        let detail = try #require(model.branch.mainDetail())
        #expect(detail.value == "2 ahead, 3 behind origin/main")
        #expect(detail.detail == "origin/main has 3 commits this branch doesn't")
        #expect(!detail.conflicts)
    }

    @Test func aBranchWithEveryCommitOnMainSaysHowFarAhead() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "agent/fix", in: clones.work)
        try await commit("One", in: clones.work, file: "one.txt", text: "1\n")
        try await git("push", "--quiet", "--set-upstream", "origin", "HEAD", in: clones.work)
        let model = try await measuredModel(clones)
        #expect(model.branch.mainLine().words == "1 ahead of origin/main")
        #expect(model.branch.mainDetail()?.detail == "Has every commit on origin/main")
        #expect(model.branch.upstreamDetail()?.value == "origin/agent/fix")
        #expect(model.branch.upstreamDetail()?.detail?.hasPrefix("Up to date") == true)
    }

    @Test func aMergeThatWouldConflictComesFirstAndIsNeverCut() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "agent/fix", in: clones.work)
        try await commit("Mine", in: clones.work, file: "src/app.txt", text: "one\nmine\n")
        try await pushFromOther(clones, file: "src/app.txt", text: "one\ntheirs\n")
        try await git("fetch", "--quiet", in: clones.work)
        let model = try await measuredModel(clones)
        // How far ahead gives way to the conflict, and the popover has both.
        #expect(model.branch.mainLine().words == "1 behind origin/main · not pushed yet")
        #expect(model.branch.mainLine().conflicts == "1 file would conflict")
        let detail = try #require(model.branch.mainDetail())
        #expect(detail.value == "1 ahead, 1 behind origin/main")
        #expect(detail.detail == "Merging it would conflict in app.txt")
        #expect(detail.conflicts)
    }

    @Test func itsWorkedOutAgainWhenMainMoves() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "agent/fix", in: clones.work)
        try await commit("One", in: clones.work, file: "one.txt", text: "1\n")
        let model = try await measuredModel(clones)
        #expect(model.branch.mainDistance?.behind == 0)
        try await pushFromOther(clones, file: "main.txt", text: "main\n")
        try await git("fetch", "--quiet", in: clones.work)
        await model.branch.refresh()
        await model.branch.measuring?.value
        #expect(model.branch.mainDistance?.behind == 1)
    }

    @Test func aDistanceIsntSaidForAnotherBranchAfterACheckout() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "agent/fix", in: clones.work)
        try await commit("One", in: clones.work, file: "one.txt", text: "1\n")
        let model = try await measuredModel(clones)
        #expect(model.branch.mainDistance != nil)
        try await git("switch", "--quiet", "main", in: clones.work)
        await model.branch.refresh()
        #expect(model.branch.mainDistance == nil)
    }

    @Test func rebaseOntoMainAsksAboutTheRemotesMain() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "agent/fix", in: clones.work)
        try await commit("One", in: clones.work, file: "one.txt", text: "1\n")
        try await pushFromOther(clones, file: "main.txt", text: "main\n")
        try await git("fetch", "--quiet", in: clones.work)
        let model = try await measuredModel(clones)
        model.branch.rebaseOntoMain()
        await model.branch.preparingIntegration?.value
        let pending = try #require(model.branch.pendingIntegration)
        #expect(pending.integration.ref == "refs/remotes/origin/main")
        #expect(pending.integration.way == .rebase)
    }
}
