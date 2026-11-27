import Foundation
import GitCore
import GitRunner
import MenuUI
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

    @Test func aHeadersTooltipSaysHowManyInWords() {
        #expect(RefsModel.Section.branches.counted(1) == "1 branch")
        #expect(RefsModel.Section.branches.counted(1_200) == "1,200 branches")
        #expect(RefsModel.Section.stashes.counted(2) == "2 stashes")
        #expect(RefsModel.Section.tags.counted(0) == "0 tags")
        #expect(RefsModel.Section.submodules.counted(3) == "3 submodules")
    }

    @Test func thePanelsMenuSaysHowRefsAreSortedInASubmenu() {
        var sorted: [RefsModel.Sort] = []
        var isHidden = false
        let entries = RefsPanel.panelMenu(sort: .date, setSort: { sorted.append($0) }, filter: {}, collapseAll: {}, expandAll: {}, hide: { isHidden = true })
        guard case let .submenu(title, value, _, options) = entries.first else {
            Issue.record("Sorting comes first, in a submenu.")
            return
        }
        #expect(title.plain == "Sort by")
        #expect(value == "Date")
        let choices = options.compactMap { entry -> (String, Bool)? in
            if case let .option(title, isChecked, _) = entry { (title.plain, isChecked) } else { nil }
        }
        #expect(choices.map { $0.0 } == ["Name", "Date"])
        #expect(choices.map { $0.1 } == [false, true])
        if case let .option(_, _, action) = options[0] { action() }
        #expect(sorted == [.name])
        for case let .command(title, _, _, shortcut, action) in entries where title.plain == "Hide refs" {
            #expect(shortcut == RefMenu.Shortcut("i", modifiers: [.control, .command]))
            action()
        }
        #expect(isHidden)
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

    func id(_ hex: String) -> ObjectID { ObjectID(hex: hex)! }

    /// Branches as this repository had them when decision 118 was drawn.
    var shimmer: BranchDetails {
        BranchDetails(
            name: "refs/heads/tm/agent-line-shimmer", tip: id, date: 1_000,
            worktree: "/work/agent-chip-shimmer", isWorktreeLocked: true,
            comparison: BranchComparison(other: "origin/tm/agent-line-shimmer", ahead: 0, behind: 0),
            upstream: "refs/remotes/origin/tm/agent-line-shimmer",
            main: BranchComparison(other: "main", ahead: 0, behind: 1),
            isMerged: true
        )
    }

    var separator: BranchDetails {
        let fromMain = BranchComparison(other: "main", ahead: 1, behind: 120)
        return BranchDetails(name: "refs/heads/tm/code-font-separator", tip: id, date: 1_000, comparison: fromMain, main: fromMain)
    }

    var reported: BranchDetails {
        let fromMain = BranchComparison(other: "main", ahead: 0, behind: 103)
        return BranchDetails(
            name: "refs/heads/tm/report-an-issue", tip: id, date: 1_000, comparison: fromMain,
            goneUpstream: "refs/remotes/origin/tm/report-an-issue", main: fromMain, isMerged: true
        )
    }

    var main: BranchDetails {
        BranchDetails(
            name: "refs/heads/main", tip: id, date: 1_000,
            comparison: BranchComparison(other: "origin/main", ahead: 0, behind: 9), upstream: "refs/remotes/origin/main"
        )
    }

    @Test func aBranchsRowSaysItsCountsOrThatItsMerged() {
        #expect(shimmer.rowState(isCurrent: true) == .checkedOut)
        #expect(shimmer.rowState(isCurrent: false) == .merged)
        // Behind its upstream, in the tabs' gray.
        #expect(main.rowState(isCurrent: false) == .counts(behind: 9, ahead: 0))
        // Without an upstream, only what main doesn't have counts, and how
        // far behind main it is goes to the tooltip.
        #expect(separator.rowState(isCurrent: false) == .counts(behind: 0, ahead: 1))
        #expect(reported.rowState(isCurrent: false) == .merged)
        #expect(branch("quiet").rowState(isCurrent: false) == .quiet)
    }

    @Test func aMergedBranchsNameIsGrayUnlessSomethingHasItCheckedOut() {
        #expect(reported.isDone(isCurrent: false))
        #expect(!reported.isDone(isCurrent: true))
        #expect(!shimmer.isDone(isCurrent: false))
        #expect(!separator.isDone(isCurrent: false))
    }

    @Test func aBranchsTooltipSaysWhereItIsAndHowFarItIs() {
        let now = Date(timeIntervalSince1970: 1_000 + 7_200)
        let lines = shimmer.details(isCurrent: false, now: now)
        #expect(Array(lines.dropLast()) == [
            "In the worktree agent-chip-shimmer, which is locked",
            "Up to date with origin/tm/agent-line-shimmer",
            "Merged into main",
        ])
        #expect(lines.last?.contains("2 hours ago") == true)
        #expect(shimmer.details(isCurrent: true, now: now).first == "Checked out here")
        #expect(separator.details(isCurrent: false, now: now).dropLast() == ["No upstream", "1 ahead, 120 behind main"])
        #expect(reported.details(isCurrent: false, now: now).dropLast() == ["Its upstream, origin/tm/report-an-issue, is gone", "Merged into main"])
        #expect(main.details(isCurrent: false, now: now).dropLast() == ["9 behind origin/main"])
    }

    @Test func aRemoteBranchsTooltipSaysWhichBranchesTrackIt() {
        let now = Date(timeIntervalSince1970: 1_000 + 7_200)
        let merged = RemoteBranchDetails(
            name: "refs/remotes/origin/tm/x", shortName: "tm/x", tip: id, date: 1_000,
            main: BranchComparison(other: "main", ahead: 0, behind: 4), isMerged: true
        )
        #expect(merged.details(trackedBy: ["tm/x"], now: now).dropLast() == ["Tracked by tm/x", "Merged into main"])
        #expect(merged.details(trackedBy: [], now: now).first == "No branch here tracks it")
        #expect(merged.details(trackedBy: ["a", "b", "c"], now: now).first == "Tracked by a and 2 more")
    }

    @Test func pointingAtABranchLightsUpItsUpstreamAndItsTab() {
        let details = RefDetails(
            currentBranch: "refs/heads/main",
            branches: [main, shimmer, separator],
            remotes: [RemoteDetails(name: "origin", branches: [
                remoteBranch("main"),
                remoteBranch("tm/agent-line-shimmer"),
                remoteBranch("tm/gone-from-the-list"),
            ])]
        )
        // A local branch: its upstream's row and its worktree's tab.
        #expect(RefsModel.links(for: .ref(shimmer.name), in: details) == RefsModel.Links(
            refs: ["refs/remotes/origin/tm/agent-line-shimmer"], worktree: "/work/agent-chip-shimmer"
        ))
        // A remote branch: the branches that track it, and their tab.
        #expect(RefsModel.links(for: .ref("refs/remotes/origin/tm/agent-line-shimmer"), in: details) == RefsModel.Links(
            refs: [shimmer.name], worktree: "/work/agent-chip-shimmer"
        ))
        // The current branch lights up in its green.
        #expect(RefsModel.links(for: .ref("refs/remotes/origin/main"), in: details).isCurrent)
        #expect(RefsModel.links(for: .ref(main.name), in: details).isCurrent)
        // A tab: its branch's row.
        #expect(RefsModel.links(for: .worktree("/work/agent-chip-shimmer"), in: details) == RefsModel.Links(refs: [shimmer.name]))
        // Nothing goes with a branch that has no upstream and no worktree.
        #expect(RefsModel.links(for: .ref(separator.name), in: details) == RefsModel.Links())
        #expect(RefsModel.links(for: nil, in: details) == RefsModel.Links())
    }

    @Test func aPillNamesARowOutOfViewAndPointsTowardIt() {
        let links = RefsModel.Links(refs: ["refs/remotes/origin/tm/x"], worktree: nil, isCurrent: true)
        let order = ["refs/heads/main": 0, "refs/heads/tm/x": 1, "refs/remotes/origin/main": 2, "refs/remotes/origin/tm/x": 3]
        #expect(RefsModel.pill(for: links, visible: ["refs/heads/main", "refs/heads/tm/x"], order: order)
            == RefsModel.Pill(name: "origin/tm/x", isBelow: true, isCurrent: true))
        #expect(RefsModel.pill(for: links, visible: ["refs/remotes/origin/tm/x"], order: order) == nil)
        let up = RefsModel.Links(refs: ["refs/heads/main"])
        #expect(RefsModel.pill(for: up, visible: ["refs/remotes/origin/tm/x"], order: order)?.isBelow == false)
        // A remote branch in a closed folder is still below.
        #expect(RefsModel.pill(for: RefsModel.Links(refs: ["refs/remotes/origin/hidden"]), visible: [], order: order)?.isBelow == true)
        #expect(RefsModel.pill(for: RefsModel.Links(), visible: [], order: order) == nil)
    }

    @Test func theButtonDeletesTheMergedBranchesNoWorktreeHas() {
        var current = reported
        current.name = "refs/heads/tm/current"
        let details = RefDetails(currentBranch: current.name, branches: [shimmer, separator, reported, current, main])
        #expect(RefsModel.deletableMergedBranches(in: details).map(\.name) == [reported.name])
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
