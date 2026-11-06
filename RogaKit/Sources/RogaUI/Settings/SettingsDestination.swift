import AgentEngine
import Foundation
import SwiftUI

/// Where Settings opens: one of its pages, or an agent's own page, which
/// belongs to Agents. Commands elsewhere in Roga open Settings at the setting
/// they're about, such as Agent Settings… after Generate fails.
enum SettingsDestination: Equatable {
    case page(SettingsPage)
    case agent(AgentKind)

    /// Where Settings keeps its page, so it opens where it was last.
    static let pageKey = "settingsPage"
    /// Where Settings keeps the agent whose page shows, as an `AgentKind` raw
    /// value. While it's absent, the page itself shows.
    static let agentKey = "settingsAgent"

    /// What's stored for a page and an agent. An agent's page shows only
    /// under Agents.
    init(page: SettingsPage, agent: AgentKind?) {
        if page == .agents, let agent {
            self = .agent(agent)
        } else {
            self = .page(page)
        }
    }

    /// The page in Settings' sidebar that shows as selected.
    var page: SettingsPage {
        switch self {
        case .page(let page): page
        case .agent: .agents
        }
    }

    /// Stores it where Settings reads its page, so that the sheet opens there,
    /// or goes there if it's showing.
    func store(in defaults: UserDefaults = .standard) {
        defaults.set(page.rawValue, forKey: Self.pageKey)
        if case .agent(let kind) = self {
            defaults.set(kind.rawValue, forKey: Self.agentKey)
        } else {
            defaults.removeObject(forKey: Self.agentKey)
        }
    }
}

/// What shows Settings at a page or an agent's page, on one window, called as
/// `openSettings(.agent(.claude))`.
///
/// It's a value that stays equal for its window, rather than a closure, the way
/// SwiftUI's own actions are: SwiftUI can't compare closures, so a new one each
/// time the window's view updates would update every view that reads it, and
/// every menu command too. SwiftUI compares them wherever it updates views, so
/// it's nonisolated.
nonisolated struct ShowSettingsAction: Equatable {
    /// Which window it shows Settings on, or nil outside any window. Two
    /// actions for the same window do the same thing.
    private let window: UUID?
    private let show: (SettingsDestination) -> Void

    init(window: UUID, show: @escaping (SettingsDestination) -> Void) {
        self.window = window
        self.show = show
    }

    /// The action outside any window, which does nothing.
    init() {
        window = nil
        show = { _ in }
    }

    func callAsFunction(_ destination: SettingsDestination) {
        show(destination)
    }

    static func == (first: ShowSettingsAction, second: ShowSettingsAction) -> Bool {
        first.window == second.window
    }
}

extension EnvironmentValues {
    /// Shows Settings at a page or an agent's page, on the window the view is
    /// in. Every Roga window provides it.
    @Entry var openSettings = ShowSettingsAction()
}

extension FocusedValues {
    /// Shows Settings at a page or an agent's page, on the focused window, for
    /// menu commands such as Agent Settings….
    @Entry var openSettings: ShowSettingsAction?
}
