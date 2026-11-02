import Foundation
import GitCore
import Testing
@testable import YagaUI

@MainActor
struct SidebarLayoutTests {
    /// A repository with a main worktree and linked ones with these names, at
    /// `/git/<name>`.
    func repository(_ name: String, owner: String? = nil, linked: [String] = [], isExpanded: Bool = false, uncommitted: [String: Int] = [:], branch: String = "main") -> ListedRepository {
        let main = Worktree(path: "/git/\(name)", branch: "refs/heads/\(branch)", isMain: true)
        let others = linked.map { Worktree(path: "/git/\($0)", branch: "refs/heads/\($0)") }
        return ListedRepository(
            path: "/git/\(name)/.git",
            owner: owner,
            isExpanded: isExpanded,
            worktrees: [main] + others,
            uncommittedFiles: Dictionary(uniqueKeysWithValues: uncommitted.map { ("/git/\($0)", $1) })
        )
    }

    /// The rows as short strings, which read like the sidebar.
    func rows(
        _ repositories: [ListedRepository],
        scope: SidebarScope = .all,
        selection: WorktreeSelection? = nil,
        place: SidebarPlace = SidebarPlace(),
        unfolded: Set<SidebarFold> = []
    ) -> [String] {
        SidebarLayout(groups: RepositoryGroups(repositories), scope: scope, selection: selection, place: place, unfolded: unfolded).items.map { item in
            switch item {
            case .group(_, let title, _, let count, let isShowing): "[\(title) \(count)\(isShowing ? "" : " hidden")]"
            case .label(let title): "<\(title)>"
            case .repository(_, let title, let detail): title + (detail.map { " (\($0))" } ?? "")
            case .worktree(_, let worktree): "  " + worktree.title
            case .fold(_, let title, _): "~ " + title
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

    @Test func aCollapsedRepositoryHidesItsWorktrees() {
        let rows = rows([repository("api", owner: "acme", linked: ["a", "b"]), repository("web", owner: "acme")], scope: .organization("acme"))
        #expect(rows == ["api", "web"])
    }

    @Test func aCollapsedRepositoryStillShowsTheSelectedWorktree() {
        let api = repository("api", owner: "acme", linked: ["a", "b"])
        let rows = rows([api, repository("web", owner: "acme")], scope: .organization("acme"), selection: select(api, "b"))
        #expect(rows == ["api", "  b", "web"])
    }

    @Test func quietWorktreesFold() {
        let api = repository("api", owner: "acme", linked: ["a", "b", "c", "d"], isExpanded: true, uncommitted: ["b": 3])
        let rows = rows([api, repository("web", owner: "acme")], scope: .organization("acme"), selection: select(api, "d"))
        #expect(rows == ["api", "  b", "  d", "~ 2 quiet worktrees", "web"])
    }

    @Test func oneQuietWorktreeDoesntFold() {
        let api = repository("api", owner: "acme", linked: ["a", "b"], isExpanded: true, uncommitted: ["b": 3])
        #expect(rows([api, repository("web", owner: "acme")], scope: .organization("acme")) == ["api", "  a", "  b", "web"])
    }

    @Test func aFoldOpens() {
        let api = repository("api", owner: "acme", linked: ["a", "b", "c"], isExpanded: true)
        let rows = rows([api, repository("web", owner: "acme")], scope: .organization("acme"), unfolded: [.worktrees(api.path)])
        #expect(rows == ["api", "  a", "  b", "  c", "~ Show fewer", "web"])
    }

    // MARK: All

    @Test func allGroupsRepositoriesUnderOrganizations() {
        let rows = rows([
            repository("web", owner: "acme", uncommitted: ["web": 2]),
            repository("api", owner: "acme", uncommitted: ["api": 1]),
            repository("site", owner: "tmarkovski", uncommitted: ["site": 1]),
            repository("yaga", owner: "tmarkovski", uncommitted: ["yaga": 1]),
            repository("scratch"),
        ])
        #expect(rows == ["[acme 2]", "api", "web", "[tmarkovski 2]", "site", "yaga", "[Other 1 hidden]"])
    }

    @Test func allFoldsQuietRepositories() {
        let api = repository("api", owner: "acme")
        let rows = rows(
            [
                api,
                repository("billing", owner: "acme"),
                repository("docs", owner: "acme"),
                repository("web", owner: "acme", uncommitted: ["web": 2]),
                repository("infra", owner: "acme", isExpanded: true),
            ],
            selection: select(api, "api")
        )
        #expect(rows == ["[acme 5]", "api", "infra", "web", "~ 2 quiet repositories"])
    }

    @Test func allOpensFoldedRepositories() {
        let repositories = ["api", "billing", "docs"].map { repository($0, owner: "acme") }
        let rows = rows(repositories, unfolded: [.repositories(.organization("acme"))])
        #expect(rows == ["[acme 3]", "api", "billing", "docs", "~ Show fewer"])
    }

    @Test func aRepositoryThatCantBeFoundIsntQuiet() {
        let missing = ListedRepository(path: "/git/gone/.git", owner: "acme", state: .missing)
        let rows = rows([missing, repository("api", owner: "acme"), repository("web", owner: "acme")])
        #expect(rows == ["[acme 3]", "gone", "~ 2 quiet repositories"])
    }

    @Test func aHiddenGroupStillShowsTheSelectedRepository() {
        let api = repository("api", owner: "acme")
        var place = SidebarPlace()
        place.shownGroups[.organization("acme")] = false
        let rows = rows([api, repository("web", owner: "acme")], selection: select(api, "api"), place: place)
        #expect(rows == ["[acme 2 hidden]", "api"])
    }

    @Test func otherNamesOwnersInAll() {
        var place = SidebarPlace()
        place.shownGroups[.other] = true
        let rows = rows(
            [repository("api", owner: "acme"), repository("web", owner: "acme"), repository("linux", owner: "torvalds"), repository("scratch")],
            place: place
        )
        #expect(rows == ["[acme 2]", "~ 2 quiet repositories", "[Other 2]", "torvalds/linux", "scratch"])
    }

    @Test func allIsAPlainListWithoutOrganizations() {
        let rows = rows([repository("scratch"), repository("linux", owner: "torvalds")])
        #expect(rows == ["torvalds/linux", "scratch"])
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

    @Test func aWindowsPlaceSurvivesSaving() throws {
        var window = WorkspaceWindow(selection: WorktreeSelection(repository: "/r/.git", worktree: "/r"))
        var place = SidebarPlace()
        place.scope = .organization("acme")
        place.lastSelections[.organization("acme")] = WorktreeSelection(repository: "/r/.git", worktree: "/r")
        place.shownGroups[.other] = true
        window.sidebar = place
        let decoded = try JSONDecoder().decode(WorkspaceWindow.self, from: JSONEncoder().encode(window))
        #expect(decoded == window)
    }

    @Test func aWindowFromAnEarlierVersionStillOpens() throws {
        let saved = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","selection":{"repository":"/r/.git","worktree":"/r"}}"#
        let decoded = try JSONDecoder().decode(WorkspaceWindow.self, from: Data(saved.utf8))
        #expect(decoded.selection?.worktree == "/r")
        #expect(decoded.sidebar == nil)
    }
}
