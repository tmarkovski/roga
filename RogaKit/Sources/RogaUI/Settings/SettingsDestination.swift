import AgentEngine
import Foundation
import SwiftUI

/// A page of Settings that opens from a row on another page, with a back
/// button before its title, as an agent's page does.
enum SettingsSubpage: String {
    /// The repositories whose identity isn't the global one, from Git's
    /// Identity section.
    case repositoryOverrides

    /// The page it belongs to, which the sidebar shows as selected.
    var page: SettingsPage {
        switch self {
        case .repositoryOverrides: .git
        }
    }

    var title: String {
        switch self {
        case .repositoryOverrides: SettingsItem.identityRepositories.title
        }
    }
}

/// Where Settings opens: one of its pages, an agent's own page, custom
/// agents' too, which belongs to Agents, or a page that opens from a row,
/// such as Repository overrides. Commands elsewhere in Roga open Settings at
/// the setting they're about, such as Agent Settings… after Generate fails.
enum SettingsDestination: Equatable {
    case page(SettingsPage)
    case agent(AgentID)
    case subpage(SettingsSubpage)

    /// Where Settings keeps its page, so it opens where it was last.
    static let pageKey = "settingsPage"
    /// Where Settings keeps the agent whose page shows, as `AgentID.stored`.
    /// While it's absent, the page itself shows.
    static let agentKey = "settingsAgent"
    /// Where Settings keeps the subpage that shows. While it's absent, the
    /// page itself shows.
    static let subpageKey = "settingsSubpage"

    /// What's stored for a page, an agent and a subpage. An agent's page
    /// shows only under Agents, and a subpage only under its own page.
    init(page: SettingsPage, agent: AgentID?, subpage: SettingsSubpage? = nil) {
        if page == .agents, let agent {
            self = .agent(agent)
        } else if let subpage, subpage.page == page {
            self = .subpage(subpage)
        } else {
            self = .page(page)
        }
    }

    /// The page in Settings' sidebar that shows as selected.
    var page: SettingsPage {
        switch self {
        case .page(let page): page
        case .agent: .agents
        case .subpage(let subpage): subpage.page
        }
    }

    /// Stores it where Settings reads its page, so that the sheet opens there,
    /// or goes there if it's showing.
    func store(in defaults: UserDefaults = .standard) {
        defaults.set(page.rawValue, forKey: Self.pageKey)
        if case .agent(let id) = self {
            defaults.set(id.stored, forKey: Self.agentKey)
        } else {
            defaults.removeObject(forKey: Self.agentKey)
        }
        if case .subpage(let subpage) = self {
            defaults.set(subpage.rawValue, forKey: Self.subpageKey)
        } else {
            defaults.removeObject(forKey: Self.subpageKey)
        }
    }
}

/// What shows Settings at a page or an agent's page, on one window, called as
/// `openSettings(.agent(.known(.claude)))`.
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
