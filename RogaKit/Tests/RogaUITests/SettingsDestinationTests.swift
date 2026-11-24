import AgentEngine
import Foundation
import Testing
@testable import RogaUI

/// Where Settings opens, and the action that opens it there.
@Suite(.timeLimit(.minutes(1)))
struct SettingsDestinationTests {
    @Test func anAgentsPageBelongsToAgents() {
        let ollama = UUID()
        #expect(SettingsDestination(page: .agents, agent: .known(.codex)) == .agent(.known(.codex)))
        #expect(SettingsDestination(page: .agents, agent: .custom(ollama)) == .agent(.custom(ollama)))
        #expect(SettingsDestination(page: .agents, agent: nil) == .page(.agents))
        // An agent stored with another page is left over, and the page shows.
        #expect(SettingsDestination(page: .git, agent: .known(.claude)) == .page(.git))
        #expect(SettingsDestination.agent(.known(.claude)).page == .agents)
    }

    @Test func storingSaysWhereTheSheetOpens() {
        let (defaults, name) = AgentTestSupport.defaults()
        defer { AgentTestSupport.remove(defaults, named: name) }
        SettingsDestination.agent(.known(.claude)).store(in: defaults)
        #expect(defaults.string(forKey: SettingsDestination.pageKey) == "agents")
        #expect(defaults.string(forKey: SettingsDestination.agentKey) == "claude")
        SettingsDestination.page(.git).store(in: defaults)
        #expect(defaults.string(forKey: SettingsDestination.pageKey) == "git")
        #expect(defaults.string(forKey: SettingsDestination.agentKey) == nil)
    }

    @Test func theCommitAndAdvancedPagesAreGone() {
        // They folded into Git (decisions 89 and 90), so a stored `commit` or
        // `advanced` is a page Settings doesn't know, and it opens on General.
        #expect(SettingsPage(rawValue: "commit") == nil)
        #expect(SettingsPage(rawValue: "advanced") == nil)
        #expect(SettingsPage.groups == [[.general, .appearance], [.git], [.agents]])
        // Git has Advanced's one group after Fetching, and commit messages
        // last.
        let git = SettingsGroup.shown().filter { $0.page == .git }
        #expect(git == [.installation, .identity, .identityExceptions, .fetching, .largeRepositories, .generate])
        #expect(SettingsGroup.largeRepositories.items == [.keepsCommitGraphCurrent])
    }

    @Test func theActionStaysEqualForItsWindow() {
        // A window makes a new one each time its view updates, and views that
        // read it update only when it's no longer equal.
        let window = UUID()
        var shown: [SettingsDestination] = []
        let first = ShowSettingsAction(window: window) { shown.append($0) }
        let again = ShowSettingsAction(window: window) { shown.append($0) }
        #expect(first == again)
        #expect(first != ShowSettingsAction(window: UUID()) { _ in })
        #expect(ShowSettingsAction() == ShowSettingsAction())
        #expect(ShowSettingsAction() != first)

        first(.agent(.known(.codex)))
        again(.page(.git))
        #expect(shown == [.agent(.known(.codex)), .page(.git)])
        // Outside a window it does nothing.
        ShowSettingsAction()(.page(.agents))
        #expect(shown.count == 2)
    }
}
