import AgentEngine
import Foundation
import Testing
@testable import RogaUI

/// Where Settings opens, and the action that opens it there.
@Suite(.timeLimit(.minutes(1)))
struct SettingsDestinationTests {
    @Test func anAgentsPageBelongsToAgents() {
        #expect(SettingsDestination(page: .agents, agent: .codex) == .agent(.codex))
        #expect(SettingsDestination(page: .agents, agent: nil) == .page(.agents))
        // An agent stored with another page is left over, and the page shows.
        #expect(SettingsDestination(page: .commit, agent: .claude) == .page(.commit))
        #expect(SettingsDestination.agent(.claude).page == .agents)
    }

    @Test func storingSaysWhereTheSheetOpens() {
        let (defaults, name) = AgentTestSupport.defaults()
        defer { AgentTestSupport.remove(defaults, named: name) }
        SettingsDestination.agent(.claude).store(in: defaults)
        #expect(defaults.string(forKey: SettingsDestination.pageKey) == "agents")
        #expect(defaults.string(forKey: SettingsDestination.agentKey) == "claude")
        SettingsDestination.page(.commit).store(in: defaults)
        #expect(defaults.string(forKey: SettingsDestination.pageKey) == "commit")
        #expect(defaults.string(forKey: SettingsDestination.agentKey) == nil)
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

        first(.agent(.codex))
        again(.page(.commit))
        #expect(shown == [.agent(.codex), .page(.commit)])
        // Outside a window it does nothing.
        ShowSettingsAction()(.page(.agents))
        #expect(shown.count == 2)
    }
}
