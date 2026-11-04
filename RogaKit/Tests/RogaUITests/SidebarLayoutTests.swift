import Foundation
import GitCore
import Testing
@testable import RogaUI

@MainActor
struct SidebarLayoutTests {
    /// A repository with a main worktree and linked ones with these names, at
    /// `/git/<name>`.
    func repository(_ name: String, owner: String? = nil, moreOwners: [String] = [], linked: [String] = [], isExpanded: Bool = false, kept: [String] = [], uncommitted: [String: Int] = [:], branch: String = "main") -> ListedRepository {
        let main = Worktree(path: "/git/\(name)", branch: "refs/heads/\(branch)", isMain: true)
        let others = linked.map { Worktree(path: "/git/\($0)", branch: "refs/heads/\($0)") }
        return ListedRepository(
            path: "/git/\(name)/.git",
            owners: (owner.map { [$0] } ?? []) + moreOwners,
            isExpanded: isExpanded,
            keptWorktrees: Set(kept.map { "/git/\($0)" }),
            worktrees: [main] + others,
            uncommittedFiles: Dictionary(uniqueKeysWithValues: uncommitted.map { ("/git/\($0)", $1) })
        )
    }

    /// The rows as short strings, which read like the sidebar.
    func rows(
        _ repositories: [ListedRepository],
        scope: SidebarScope = .all,
        selection: WorktreeSelection? = nil,
        place: SidebarPlace = SidebarPlace()
    ) -> [String] {
        SidebarLayout(groups: RepositoryGroups(repositories), scope: scope, selection: selection, place: place).items.map { item in
            switch item {
            case .label(let title): "<\(title)>"
            case .repository(_, let title, let detail): title + (detail.map { " (\($0))" } ?? "")
            case .worktree(_, let worktree, let isLast): (isLast ? "└ " : "│ ") + worktree.title
            case .hiddenWorktrees(_, let title, let uncommittedFiles, _): "└ " + title + (uncommittedFiles > 0 ? " (\(uncommittedFiles))" : "")
            }
        }
    }

    func select(_ repository: ListedRepository, _ worktree: String) -> WorktreeSelection {
        WorktreeSelection(repository: repository.path, worktree: "/git/\(worktree)")
    }

    // MARK: Groups

    @Test func anOwnerNeedsTwoRepositoriesForAPlaceOnTheRail() {
        let groups = RepositoryGroups([
            repository("web", owner: "acme"),
            repository("api", owner: "Acme"),
            repository("linux", owner: "torvalds"),
            repository("scratch"),
        ])
        #expect(groups.organizations.map(\.id) == ["acme"])
        #expect(groups.organizations[0].repositories.map(\.name) == ["api", "web"])
        #expect(groups.otherOwners.map(\.name) == ["linux"])
        #expect(groups.noRemote.map(\.name) == ["scratch"])
        #expect(groups.scopes == [.all, .organization("acme"), .other])
    }

    @Test func anyRemoteCanPutARepositoryInAnOrganization() {
        let client = repository("submissions", owner: "northwind", moreOwners: ["Acme"])
        let groups = RepositoryGroups([client, repository("api", owner: "acme")])
        #expect(groups.organizations.map(\.id) == ["acme"])
        #expect(groups.organizations[0].repositories.map(\.name) == ["api", "submissions"])
        #expect(groups.otherOwners.isEmpty)
        #expect(groups.scopes == [.all, .organization("acme")])
        #expect(groups.scopes(of: client) == [.organization("acme")])
    }

    @Test func aRepositoryIsListedInEachOfItsOrganizations() {
        let shared = repository("shared", owner: "acme", moreOwners: ["northwind"])
        let groups = RepositoryGroups([shared, repository("api", owner: "acme"), repository("web", owner: "northwind")])
        #expect(groups.repositories(in: .organization("acme")).map(\.name) == ["api", "shared"])
        #expect(groups.repositories(in: .organization("northwind")).map(\.name) == ["shared", "web"])
        #expect(groups.all.map(\.name) == ["api", "shared", "web"])
        #expect(groups.scopes(of: shared) == [.organization("acme"), .organization("northwind")])
    }

    @Test func aRepositoryWithOwnersThatHaveNoOthersIsInOtherOnce() {
        let linux = repository("linux", owner: "torvalds", moreOwners: ["mirrors"])
        let groups = RepositoryGroups([linux])
        #expect(groups.organizations.isEmpty)
        #expect(groups.otherOwners.map(\.nameWithOwner) == ["torvalds/linux"])
        #expect(groups.repositories(in: .other).count == 1)
        #expect(groups.scopes(of: linux) == [.other])
    }

    @Test func aCloneIsListedWhereItsOwnersAre() {
        let groups = RepositoryGroups([repository("api", owner: "acme"), repository("web", owner: "acme")])
        #expect(groups.scopes(ofOwners: ["northwind", "ACME"]) == [.organization("acme")])
        #expect(groups.scopes(ofOwners: ["northwind"]) == [.other])
        #expect(groups.scopes(ofOwners: []) == [.other])
    }

    @Test func theRailListsOrganizationsFromAToZ() {
        let groups = RepositoryGroups(["zeta", "acme", "beta"].flatMap { owner in
            [repository(owner + "1", owner: owner), repository(owner + "2", owner: owner)]
        })
        #expect(groups.scopes == [.all, .organization("acme"), .organization("beta"), .organization("zeta")])
    }

    @Test func otherLeavesTheRailWhenItsEmpty() {
        let groups = RepositoryGroups([repository("api", owner: "acme"), repository("web", owner: "acme")])
        #expect(groups.scopes == [.all, .organization("acme")])
    }

    @Test func monogramsHaveTwoLetters() {
        #expect(RepositoryOrganization.monogram("acme") == "AC")
        #expect(RepositoryOrganization.monogram("open-source") == "OS")
        #expect(RepositoryOrganization.monogram("x") == "X")
    }

    // MARK: A scope's rows

    @Test func anOrganizationListsItsRepositoriesFromAToZ() {
        let rows = rows(
            [repository("web", owner: "acme"), repository("api", owner: "acme"), repository("scratch")],
            scope: .organization("acme")
        )
        #expect(rows == ["api", "web"])
    }

    @Test func otherSeparatesOwnersFromRepositoriesWithoutARemote() {
        let rows = rows(
            [repository("linux", owner: "torvalds"), repository("git", owner: "git"), repository("scratch")],
            scope: .other
        )
        #expect(rows == ["<Other owners>", "git/git", "torvalds/linux", "<No remote>", "scratch"])
    }

    @Test func otherLeavesOutAnEmptySection() {
        #expect(rows([repository("scratch")], scope: .other) == ["<No remote>", "scratch"])
    }

    @Test func aRowShowsAnUnusualBranch() {
        let rows = rows([repository("auth", owner: "acme", branch: "release/2.3"), repository("api", owner: "acme", branch: "master")], scope: .organization("acme"))
        #expect(rows == ["api", "auth (release/2.3)"])
    }

    @Test func aRowShowsTheFolderWhenTwoHaveTheSameName() {
        let first = ListedRepository(path: "/git/one/api/.git", worktrees: [Worktree(path: "/git/one/api", branch: "refs/heads/feature", isMain: true)])
        let second = ListedRepository(path: "/git/two/api/.git", worktrees: [Worktree(path: "/git/two/api", branch: "refs/heads/main", isMain: true)])
        #expect(rows([second, first]) == ["api (/git/one)", "api (/git/two)"])
    }

    // MARK: Worktrees

    @Test func aRepositoryWithoutLinkedWorktreesHasNoRowsUnderIt() {
        #expect(rows([repository("api", owner: "acme", isExpanded: true), repository("web", owner: "acme")], scope: .organization("acme")) == ["api", "web"])
    }

    @Test func aCollapsedRepositoryHasARowForItsWorktrees() {
        let rows = rows([repository("api", owner: "acme", linked: ["a", "b"]), repository("web", owner: "acme", linked: ["c"])], scope: .organization("acme"))
        #expect(rows == ["api", "└ 2 worktrees", "web", "└ 1 worktree"])
    }

    @Test func thatRowCountsTheUncommittedFilesItHides() {
        let api = repository("api", owner: "acme", linked: ["a", "b"], uncommitted: ["api": 7, "a": 2, "b": 3])
        #expect(rows([api, repository("web", owner: "acme")], scope: .organization("acme")) == ["api", "└ 2 worktrees (5)", "web"])
    }

    @Test func thatRowSaysWhenAWorktreeItHidesHasConflicts() throws {
        let worktrees = [
            Worktree(path: "/git/api", branch: "refs/heads/main", isMain: true),
            Worktree(path: "/git/a", branch: "refs/heads/a"),
            Worktree(path: "/git/b", branch: "refs/heads/b"),
        ]
        func hidesConflicts(in conflicted: Set<String>) throws -> Bool {
            let api = ListedRepository(path: "/git/api/.git", owners: ["acme"], worktrees: worktrees, conflictedWorktrees: conflicted)
            let items = SidebarLayout(groups: RepositoryGroups([api]), scope: .all, selection: nil, place: SidebarPlace()).items
            guard case .hiddenWorktrees(_, _, _, let hasConflicts) = try #require(items.last) else {
                Issue.record("There's no row for hidden worktrees.")
                return false
            }
            return hasConflicts
        }
        #expect(try hidesConflicts(in: ["/git/b"]))
        #expect(try !hidesConflicts(in: []))
        // The main worktree has its own row, so this one isn't hiding that.
        #expect(try !hidesConflicts(in: ["/git/api"]))
    }

    @Test func aCollapsedRepositoryStillShowsTheSelectedWorktree() {
        let api = repository("api", owner: "acme", linked: ["a", "b"], uncommitted: ["a": 2, "b": 3])
        let rows = rows([api, repository("web", owner: "acme")], scope: .organization("acme"), selection: select(api, "b"))
        #expect(rows == ["api", "│ b", "└ 1 more worktree (2)", "web"])
    }

    @Test func theSelectedWorktreeEndsTheLineWhenItsTheOnlyOne() {
        let api = repository("api", owner: "acme", linked: ["a"])
        #expect(rows([api, repository("web", owner: "acme")], scope: .organization("acme"), selection: select(api, "a")) == ["api", "└ a", "web"])
    }

    @Test func aCollapsedRepositoryShowsTheWorktreesItKept() {
        let api = repository("api", owner: "acme", linked: ["a", "b", "c"], kept: ["a"])
        #expect(rows([api, repository("web", owner: "acme")], scope: .organization("acme")) == ["api", "│ a", "└ 2 more worktrees", "web"])
    }

    @Test func aKeptWorktreeShowsWithTheSelectedOne() {
        let api = repository("api", owner: "acme", linked: ["a", "b", "c"], kept: ["a"])
        let rows = rows([api, repository("web", owner: "acme")], scope: .organization("acme"), selection: select(api, "c"))
        #expect(rows == ["api", "│ a", "│ c", "└ 1 more worktree", "web"])
    }

    @Test func aKeptWorktreeEndsTheLineWhenNothingIsHidden() {
        let api = repository("api", owner: "acme", linked: ["a"], kept: ["a"])
        #expect(rows([api, repository("web", owner: "acme")], scope: .organization("acme")) == ["api", "└ a", "web"])
    }

    @Test func anExpandedRepositoryShowsEveryWorktree() {
        let api = repository("api", owner: "acme", linked: ["a", "b", "c"], isExpanded: true, uncommitted: ["b": 3])
        #expect(rows([api, repository("web", owner: "acme")], scope: .organization("acme")) == ["api", "│ a", "│ b", "└ c", "web"])
    }

    // MARK: All

    @Test func allListsEveryRepositoryFromAToZ() {
        let rows = rows([
            repository("roga", owner: "tmarkovski"),
            repository("web", owner: "acme"),
            repository("site", owner: "tmarkovski"),
            repository("api", owner: "acme"),
            repository("linux", owner: "torvalds"),
            repository("scratch"),
        ])
        #expect(rows == ["api", "linux", "roga", "scratch", "site", "web"])
    }

    @Test func allStillShowsWorktreesUnderTheirRepository() {
        let rows = rows([
            repository("web", owner: "acme"),
            repository("api", owner: "acme", linked: ["fix-login"], isExpanded: true),
        ])
        #expect(rows == ["api", "└ fix-login", "web"])
    }

    // MARK: Where a window is

    @Test func theRailFallsBackToAll() {
        let groups = RepositoryGroups([repository("api", owner: "acme"), repository("web", owner: "acme")])
        var place = SidebarPlace()
        place.scope = .organization("acme")
        #expect(place.effectiveScope(in: groups, showsRail: true) == .organization("acme"))
        #expect(place.effectiveScope(in: groups, showsRail: false) == .all)
        place.scope = .organization("gone")
        #expect(place.effectiveScope(in: groups, showsRail: true) == .all)
    }

    @Test func aSelectionMovesTheSidebarToWhereItsListed() {
        let web = repository("web", owner: "acme")
        let groups = RepositoryGroups([repository("api", owner: "acme"), web, repository("scratch")])
        var place = SidebarPlace()
        place.scope = .other
        place.record(web.home, in: groups)
        #expect(place.scope == .organization("acme"))
        #expect(place.lastSelections[.organization("acme")] == web.home)
    }

    @Test func aSelectionLeavesAllAlone() {
        let web = repository("web", owner: "acme")
        let groups = RepositoryGroups([repository("api", owner: "acme"), web])
        var place = SidebarPlace()
        place.record(web.home, in: groups)
        #expect(place.scope == .all)
        #expect(place.lastSelections[.organization("acme")] == web.home)
    }

    @Test func aSelectionInSeveralOrganizationsStaysInTheOneItsIn() {
        let shared = repository("shared", owner: "acme", moreOwners: ["northwind"])
        let web = repository("web", owner: "northwind")
        let groups = RepositoryGroups([shared, repository("api", owner: "acme"), web])
        var place = SidebarPlace()
        place.scope = .organization("northwind")
        place.lastSelections[.organization("acme")] = web.home
        place.record(shared.home, in: groups)
        #expect(place.scope == .organization("northwind"))
        #expect(place.lastSelections[.organization("northwind")] == shared.home)
        #expect(place.lastSelections[.organization("acme")] == web.home)
    }

    @Test func aSelectionInSeveralOrganizationsMovesTheSidebarToTheFirst() {
        let shared = repository("shared", owner: "acme", moreOwners: ["northwind"])
        let groups = RepositoryGroups([shared, repository("api", owner: "acme"), repository("web", owner: "northwind"), repository("scratch")])
        var place = SidebarPlace()
        place.scope = .other
        place.record(shared.home, in: groups)
        #expect(place.scope == .organization("acme"))
        #expect(place.lastSelections[.organization("acme")] == shared.home)
    }

    @Test func aSelectionFromAllCountsInEachOfItsOrganizations() {
        let shared = repository("shared", owner: "acme", moreOwners: ["northwind"])
        let groups = RepositoryGroups([shared, repository("api", owner: "acme"), repository("web", owner: "northwind")])
        var place = SidebarPlace()
        place.record(shared.home, in: groups)
        #expect(place.scope == .all)
        #expect(place.lastSelections[.organization("acme")] == shared.home)
        #expect(place.lastSelections[.organization("northwind")] == shared.home)
    }

    @Test func aWindowsPlaceSurvivesSaving() throws {
        var window = WorkspaceWindow(selection: WorktreeSelection(repository: "/r/.git", worktree: "/r"))
        var place = SidebarPlace()
        place.scope = .organization("acme")
        place.lastSelections[.organization("acme")] = WorktreeSelection(repository: "/r/.git", worktree: "/r")
        window.sidebar = place
        let decoded = try JSONDecoder().decode(WorkspaceWindow.self, from: JSONEncoder().encode(window))
        #expect(decoded == window)
    }

    @Test func aWindowThatSavedTheOldGroupsStillOpens() throws {
        let saved = #"{"scope":{"all":{}},"lastSelections":[],"shownGroups":[]}"#
        #expect(try JSONDecoder().decode(SidebarPlace.self, from: Data(saved.utf8)).scope == .all)
    }

    @Test func aWindowFromAnEarlierVersionStillOpens() throws {
        let saved = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","selection":{"repository":"/r/.git","worktree":"/r"}}"#
        let decoded = try JSONDecoder().decode(WorkspaceWindow.self, from: Data(saved.utf8))
        #expect(decoded.selection?.worktree == "/r")
        #expect(decoded.sidebar == nil)
    }
}
