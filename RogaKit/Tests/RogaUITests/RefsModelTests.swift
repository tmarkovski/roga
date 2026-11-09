import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import SwiftUI
import TestSupport
import Testing
@testable import RogaUI

/// How the refs panel orders and narrows its lists, and how selecting a ref
/// reaches history.
@Suite(.timeLimit(.minutes(1)))
struct RefsModelTests {
    let id = ObjectID(hex: "da9ff97390adfc8a4a4b4c0f0a1481c9084145d5")!

    func branch(_ name: String, date: Int64? = nil) -> BranchDetails {
        BranchDetails(name: "refs/heads/" + name, tip: id, date: date)
    }

    func tag(_ name: String, date: Int64? = nil) -> TagDetails {
        TagDetails(name: "refs/tags/" + name, commit: id, date: date)
    }

    func remoteBranch(_ name: String, date: Int64? = nil) -> RemoteBranchDetails {
        RemoteBranchDetails(name: "refs/remotes/origin/" + name, shortName: name, tip: id, date: date)
    }

    @Test func byNameTheCurrentBranchComesFirstAndNumbersCountAsNumbers() {
        let details = RefDetails(
            currentBranch: "refs/heads/main",
            branches: [branch("agent-10"), branch("agent-9"), branch("main"), branch("Zed"), branch("apple")]
        )
        #expect(RefsModel.sorted(details, by: .name).branches.map(\.shortName) == ["main", "agent-9", "agent-10", "apple", "Zed"])
    }

    @Test func byNameTagsGoFromTheLatestVersion() {
        let details = RefDetails(tags: [tag("v0.9"), tag("v0.10"), tag("v0.1")])
        #expect(RefsModel.sorted(details, by: .name).tags.map(\.shortName) == ["v0.10", "v0.9", "v0.1"])
    }

    @Test func byDateEverythingGoesFromTheLatest() {
        let details = RefDetails(
            currentBranch: "refs/heads/old",
            branches: [branch("new", date: 3), branch("old", date: 1), branch("middle", date: 2), branch("unknown")],
            remotes: [RemoteDetails(name: "origin", branches: [remoteBranch("a", date: 1), remoteBranch("b", date: 2)])],
            tags: [tag("v1", date: 1), tag("v2", date: 2), tag("undated")]
        )
        let sorted = RefsModel.sorted(details, by: .date)
        #expect(sorted.branches.map(\.shortName) == ["old", "new", "middle", "unknown"])
        #expect(sorted.remotes[0].branches.map(\.shortName) == ["b", "a"])
        #expect(sorted.tags.map(\.shortName) == ["v2", "v1", "undated"])
    }

    @Test func tagsAndStashesGoAwayWhenThereAreNoneAndAFilterHidesAnyEmptySection() {
        for section in [RefsModel.Section.tags, .stashes] {
            #expect(!section.isShown(count: 0, isFiltering: false))
            #expect(section.isShown(count: 1, isFiltering: false))
        }
        for section in [RefsModel.Section.branches, .remotes] {
            #expect(section.isShown(count: 0, isFiltering: false))
        }
        for section in RefsModel.Section.allCases {
            #expect(!section.isShown(count: 0, isFiltering: true))
            #expect(section.isShown(count: 1, isFiltering: true))
        }
    }

    @Test func aFilterNarrowsEverySectionAndIgnoresCase() {
        let details = RefDetails(
            branches: [branch("agent/fix-login"), branch("main")],
            remotes: [
                RemoteDetails(name: "origin", branches: [remoteBranch("main"), remoteBranch("agent/LOGIN")]),
                RemoteDetails(name: "login-mirror", branches: [remoteBranch("main")]),
                RemoteDetails(name: "fork", branches: [remoteBranch("main")]),
            ],
            tags: [tag("login-1.0"), tag("v2")],
            stashes: [
                StashDetails(position: 0, commit: id, message: "On main: Try another LOGIN flow"),
                StashDetails(position: 1, commit: id, message: "WIP on main"),
            ]
        )
        let filtered = RefsModel.filtered(details, by: "login")
        #expect(filtered.branches.map(\.shortName) == ["agent/fix-login"])
        // A remote keeps the branches that match, or all of them if its own
        // name matches, and goes if neither does.
        #expect(filtered.remotes.map(\.name) == ["origin", "login-mirror"])
        #expect(filtered.remotes[0].branches.map(\.shortName) == ["agent/LOGIN"])
        #expect(filtered.remotes[1].branches.map(\.shortName) == ["main"])
        #expect(filtered.tags.map(\.shortName) == ["login-1.0"])
        #expect(filtered.stashes.map(\.position) == [0])

        #expect(RefsModel.filtered(details, by: "") == details)
    }

    /// Branch rows as text: a folder as its name with a slash, how many
    /// branches are under it and whether it's closed, and a branch as its
    /// title, each indented by how many folders it's in.
    func outline<Branch>(_ rows: [BranchRow<Branch>]) -> [String] {
        rows.map { row in
            let indent = String(repeating: "  ", count: row.depth)
            switch row.content {
            case .folder(_, let name, let count, let isCollapsed):
                return indent + name + "/ \(count)" + (isCollapsed ? " closed" : "")
            case .branch(_, let title):
                return indent + title
            }
        }
    }

    func rows(_ branches: [BranchDetails], current: String? = nil, sort: RefsModel.Sort = .name, collapsed: Set<String> = []) -> [BranchRow<BranchDetails>] {
        RefsModel.rows(of: branches, under: Ref.branchPrefix, current: current, sort: sort, collapsed: collapsed)
    }

    @Test func eachPartOfANameBeforeASlashIsAFolder() {
        let rows = rows([branch("tm/sidebar-second-line"), branch("tm/commit-experience"), branch("main"), branch("a/b/c"), branch("fix/login")])
        // By name, folders come before the other branches.
        #expect(outline(rows) == [
            "a/ 1",
            "  b/ 1",
            "    c",
            "fix/ 1",
            "  login",
            "tm/ 2",
            "  commit-experience",
            "  sidebar-second-line",
            "main",
        ])
        // A folder goes by what the full names in it start with, which no
        // branch's name can be.
        #expect(rows.map(\.id) == [
            "refs/heads/a/",
            "refs/heads/a/b/",
            "refs/heads/a/b/c",
            "refs/heads/fix/",
            "refs/heads/fix/login",
            "refs/heads/tm/",
            "refs/heads/tm/commit-experience",
            "refs/heads/tm/sidebar-second-line",
            "refs/heads/main",
        ])
    }

    @Test func theCurrentBranchComesFirstBesideItsNeighbors() {
        let branches = [branch("tm/a"), branch("tm/b"), branch("main"), branch("develop")]
        #expect(outline(rows(branches, current: "refs/heads/tm/b")) == ["tm/ 2", "  b", "  a", "develop", "main"])
        #expect(outline(rows(branches, current: "refs/heads/main")) == ["main", "tm/ 2", "  a", "  b", "develop"])
        #expect(outline(rows(branches, current: "refs/heads/main", sort: .date)) == ["main", "develop", "tm/ 2", "  a", "  b"])
    }

    @Test func byDateAFolderGoesAtTheDateOfItsLatestBranch() {
        let branches = [
            branch("tm/old", date: 1),
            branch("tm/new", date: 5),
            branch("develop", date: 3),
            branch("fix/login", date: 2),
            branch("undated"),
            branch("wip/undated"),
        ]
        #expect(outline(rows(branches, sort: .date)) == [
            "tm/ 2",
            "  new",
            "  old",
            "develop",
            "fix/ 1",
            "  login",
            "undated",
            "wip/ 1",
            "  undated",
        ])
    }

    @Test func aClosedFolderHidesWhatsInIt() {
        let rows = rows(
            [branch("a/b/c"), branch("a/d"), branch("tm/x"), branch("main")],
            collapsed: ["refs/heads/a/b/", "refs/heads/tm/"]
        )
        #expect(outline(rows) == ["a/ 2", "  b/ 1 closed", "  d", "tm/ 1 closed", "main"])
        // So the arrow keys go past what's in it, as they go past the folders.
        #expect(rows.compactMap(\.branch).map(\.shortName) == ["a/d", "main"])
    }

    @Test func aRemotesBranchesGoInFoldersOfTheirOwn() {
        let details = RefDetails(
            currentBranch: "refs/heads/main",
            branches: [branch("main"), branch("tm/x")],
            remotes: [RemoteDetails(name: "origin", branches: [remoteBranch("main"), remoteBranch("tm/x"), remoteBranch("tm/y")])]
        )
        // Closing the remote's folder leaves the local one of the same name open.
        let rows = RefsModel.branchRows(details, sort: .name, collapsed: ["refs/remotes/origin/tm/"])
        #expect(outline(rows.local) == ["main", "tm/ 1", "  x"])
        #expect(outline(rows.remotes["origin"] ?? []) == ["tm/ 2 closed", "main"])
        #expect(rows.remotes["origin"]?.first?.id == "refs/remotes/origin/tm/")
    }

    @Test func aFilterOpensTheFoldersThatHaveMatchesAndShowsOnlyThose() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "roga-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = try #require(realpath(folder.path(percentEncoded: false), nil))
        let repository = String(cString: path) + "/work"
        free(path)
        let git = try await TestGit.make()
        _ = try await git.run(GitCommand("clone", "--quiet", try await Fixture.repository("basic"), repository, in: folder.path(percentEncoded: false)))
        for name in ["tm/fix-login", "tm/sidebar", "ab/login-page"] {
            _ = try await git.run(GitCommand("branch", name, in: repository))
        }
        let session = try await RepositorySession.open(containing: repository, git: git)
        let model = RepositoryModel(session: session, worktree: repository, keepsCommitGraphCurrent: { false })
        await model.refs.load()
        let closed: Set = ["refs/heads/ab/", "refs/heads/tm/"]

        #expect(outline(try #require(model.refs.branchRows(sort: .name, collapsed: closed)).local) == ["main", "ab/ 1 closed", "tm/ 2 closed"])
        model.refs.filter = "LOGIN"
        #expect(outline(try #require(model.refs.branchRows(sort: .name, collapsed: closed)).local) == ["ab/ 1", "  login-page", "tm/ 1", "  fix-login"])
        // A folder's name matches too, and brings everything in it.
        model.refs.filter = "tm/"
        #expect(outline(try #require(model.refs.branchRows(sort: .name, collapsed: closed)).local) == ["tm/ 2", "  fix-login", "  sidebar"])
        model.refs.closeFilter()
        #expect(outline(try #require(model.refs.branchRows(sort: .name, collapsed: closed)).local) == ["main", "ab/ 1 closed", "tm/ 2 closed"])
        #expect(outline(try #require(model.refs.branchRows(sort: .name, collapsed: [])).local) == [
            "main", "ab/ 1", "  login-page", "tm/ 2", "  fix-login", "  sidebar",
        ])
    }

    @Test func aBranchSaysWhereItIsAndHowFarItIs() {
        var row = branch("agent/fix-login", date: 1_000)
        let now = Date(timeIntervalSince1970: 1_000 + 7_200)
        #expect(row.subtitle(isCurrent: false, now: now).contains("2 hours ago"))

        row.worktree = "/work/agents/fix-login"
        #expect(row.subtitle(isCurrent: false, now: now) == "in fix-login")
        // The checkmark says that already.
        #expect(row.subtitle(isCurrent: true, now: now).contains("2 hours ago"))

        row.comparison = BranchComparison(other: "main", ahead: 3, behind: 2)
        #expect(row.subtitle(isCurrent: false, now: now) == "in fix-login · 3 ahead, 2 behind main")
        #expect(row.subtitle(isCurrent: true, now: now) == "3 ahead, 2 behind main")
    }

    @Test(arguments: [
        (1, 0, "1 ahead of main"),
        (0, 2, "2 behind main"),
        (3, 2, "3 ahead, 2 behind main"),
        (0, 0, "up to date with main"),
    ])
    func describesHowFarABranchIs(ahead: Int, behind: Int, summary: String) {
        #expect(BranchComparison(other: "main", ahead: ahead, behind: behind).summary == summary)
    }

    @Test(arguments: [
        (1128.0, true),
        // The middle keeps 400 points beside a panel at its narrowest.
        (688.0, true),
        (687.5, false),
    ])
    func thePanelGivesWayWhenTheMiddleWouldGetTooNarrow(column: Double, fits: Bool) {
        #expect(RefsPanelVisibility.fits(column: column) == fits)
    }

    @Test func aPanelThatDoesntFitStaysWanted() {
        var wanted = true
        let binding = Binding { wanted } set: { wanted = $0 }
        #expect(RefsPanelVisibility(isWanted: binding, fits: true).isShowing)
        #expect(RefsPanelVisibility(isWanted: binding, fits: true).commandTitle == "Hide Refs")
        #expect(!RefsPanelVisibility(isWanted: binding, fits: false).isShowing)
        #expect(RefsPanelVisibility(isWanted: binding, fits: false).commandTitle == "Show Refs")
        #expect(wanted)
    }

    @Test func closingTheFilterListsEverythingAgain() async throws {
        let (model, _) = try await makeModel()
        #expect(!model.refs.isFilterShown)

        model.refs.showFilter()
        #expect(model.refs.isFilterShown)
        #expect(model.refs.wantsFilterFocus)

        model.refs.filter = "login"
        model.refs.closeFilter()
        #expect(!model.refs.isFilterShown)
        #expect(model.refs.filter.isEmpty)
    }

    func makeModel() async throws -> (RepositoryModel, String) {
        let repository = try await Fixture.repository("basic")
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        return (RepositoryModel(session: session, worktree: repository, keepsCommitGraphCurrent: { false }), repository)
    }

    @Test func loadsTheListsAndKeepsThemWhileReadingThemAgain() async throws {
        let (model, _) = try await makeModel()
        #expect(model.refs.content == .loading)
        #expect(model.refs.shown(sort: .name) == nil)

        await model.refs.load()
        let details = try #require(model.refs.shown(sort: .name))
        #expect(!details.branches.isEmpty)

        // Sorting again gives the same, and another order doesn't lose it.
        #expect(model.refs.shown(sort: .name) == details)
        #expect(model.refs.shown(sort: .date) != nil)
        await model.refs.load()
        #expect(model.refs.shown(sort: .name) == details)
    }

    @Test func aFailureSaysSoRatherThanShowingNoRefs() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "roga-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let repository = folder.path(percentEncoded: false)
        let git = try await TestGit.make()
        try await git.run(GitCommand("init", "--quiet", in: repository))
        let session = try await RepositorySession.open(containing: repository, git: git)
        let refs = RefsModel(session: session, worktree: repository + "/not-a-folder")

        await refs.load()
        guard case .failed(let message) = refs.content else {
            Issue.record("Expected a failure, got \(refs.content)")
            return
        }
        #expect(!message.isEmpty)
        #expect(refs.shown(sort: .name) == nil)
    }

    @Test func selectingARefSelectsItsCommitInHistory() async throws {
        let (model, _) = try await makeModel()
        await model.load()
        await model.refs.load()
        let details = try #require(model.refs.shown(sort: .name))
        let branch = try #require(details.branches.first)

        model.select(ref: branch.name, commit: branch.tip)
        #expect(model.refs.selectedRef == branch.name)
        #expect(model.selectedCommit.id == branch.tip)
        #expect(model.selectedRow != nil)

        // Stepping with the keyboard says so, for scrolling to the row.
        let steps = model.refs.selectionSteps
        model.refs.step(to: branch.name)
        #expect(model.refs.selectionSteps == steps + 1)
    }

    @Test func readsTheListsAgainWhenRogaBecomesActiveOrOnReload() async throws {
        let (model, _) = try await makeModel()
        let checks = model.refsChecks
        model.becameActive()
        #expect(model.refsChecks == checks + 1)
        model.check?.cancel()
        model.reload()
        #expect(model.refsChecks == checks + 2)
    }
}
