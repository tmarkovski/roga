import AgentEngine
import IconUI
import SwiftUI

extension UserDefaults {
    static let keepsCommitGraphCurrentKey = "keepsCommitGraphCurrent"
    static let fetchesByItselfKey = "fetchesByItself"

    /// Whether Roga keeps commit-graph files up to date, which it does unless
    /// the user turned that off (decision 6).
    var keepsCommitGraphCurrent: Bool {
        object(forKey: Self.keepsCommitGraphCurrentKey) as? Bool ?? true
    }

    /// Whether Roga fetches when it becomes active, which it does unless the
    /// user turned that off (decision 20).
    var fetchesByItself: Bool {
        object(forKey: Self.fetchesByItselfKey) as? Bool ?? true
    }
}

/// The pages of Settings, in the order its sidebar lists them.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case appearance
    case git
    case commit
    case agents
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .git: "Git"
        case .commit: "Commit"
        case .agents: "Agents"
        case .advanced: "Advanced"
        }
    }

    var icon: Icon {
        switch self {
        case .general: .slidersHorizontal
        case .appearance: .palette
        case .git: .branch
        case .commit: .gitCommitHorizontal
        case .agents: .squareTerminal
        case .advanced: .wrench
        }
    }

    /// The sidebar's groups, with a line between each, as on the canvas.
    static let groups: [[SettingsPage]] = [[.general, .appearance], [.git, .commit], [.agents], [.advanced]]
}

/// A heading on a page, and the settings under it.
enum SettingsGroup: CaseIterable {
    case openIn
    case updates
    case interface
    case motion
    case lists
    case installation
    case fetching
    case generate
    case commandLineAgents
    case workingStatus
    case largeRepositories

    var title: String {
        switch self {
        case .openIn: "Open in"
        case .updates: "Updates"
        case .interface: "Interface"
        case .motion: "Motion"
        case .lists: "Lists"
        case .installation: "Installation"
        case .fetching: "Fetching"
        case .generate: "Generate messages with an agent"
        case .commandLineAgents: "Command-line agents"
        case .workingStatus: "Working status"
        case .largeRepositories: "Large repositories"
        }
    }

    var page: SettingsPage {
        switch self {
        case .openIn, .updates: .general
        case .interface, .motion, .lists: .appearance
        case .installation, .fetching: .git
        case .generate: .commit
        case .commandLineAgents, .workingStatus: .agents
        case .largeRepositories: .advanced
        }
    }

    /// What the whole group is about, under its heading on its page.
    var description: String? {
        switch self {
        case .openIn:
            "Roga lists the terminals it finds on this Mac that can open a folder."
        case .installation:
            "Roga uses the first Git \(SetupWords.minimumGit) or newer in your login shell's PATH, unless you pick another from the menu."
        case .commandLineAgents:
            "Roga looks for these in your login shell's PATH, the way it finds git. Generating a commit message runs one on this Mac with its tools off."
        case .workingStatus:
            "Roga can show which worktrees have an agent working, finished or waiting for you. The agents tell it through their hooks, so Roga never guesses from file changes, and it ignores folders that aren't in its sidebar."
        default:
            nil
        }
    }

    /// The description as its page draws it, with names that are typed, such
    /// as PATH, in the code font, as the canvas sets them.
    var styledDescription: AttributedString? {
        description.map { AttributedString.settingsWords($0, typedNames: ["PATH"]) }
    }

    var items: [SettingsItem] {
        SettingsItem.allCases.filter { $0.group == self }
    }
}

/// Every setting, in the order the pages show them, so that search can find
/// them by their words. Some are blocks rather than rows, such as the list of
/// agents, and search finds those by what they show.
enum SettingsItem: CaseIterable {
    case terminal
    case checksForUpdates
    case downloadsUpdates
    case theme
    case animationSpeed
    case fileLayout
    case refsSort
    case foldsDescriptions
    case gitProgram
    case fetchesByItself
    case showsGenerateButton
    case generateAgent
    case generateModel
    case generateEffort
    case matchesStyle
    case instructions
    case generateCommand
    case agentList
    case hooks
    case showsMarks
    case marksLegend
    case keepsCommitGraphCurrent

    var group: SettingsGroup {
        switch self {
        case .terminal: .openIn
        case .checksForUpdates, .downloadsUpdates: .updates
        case .theme: .interface
        case .animationSpeed: .motion
        case .fileLayout, .refsSort, .foldsDescriptions: .lists
        case .gitProgram: .installation
        case .fetchesByItself: .fetching
        case .showsGenerateButton, .generateAgent, .generateModel, .generateEffort, .matchesStyle, .instructions, .generateCommand: .generate
        case .agentList: .commandLineAgents
        case .hooks, .showsMarks, .marksLegend: .workingStatus
        case .keepsCommitGraphCurrent: .largeRepositories
        }
    }

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .checksForUpdates: "Check for updates automatically"
        case .downloadsUpdates: "Download updates automatically"
        case .theme: "Theme"
        case .animationSpeed: "Animation speed"
        case .fileLayout: "Show files as"
        case .refsSort: "Sort branches by"
        case .foldsDescriptions: "Fold commit descriptions"
        case .gitProgram: "Git"
        case .fetchesByItself: "Fetch when Roga becomes active"
        case .showsGenerateButton: "Show the Generate button"
        case .generateAgent: "Agent"
        case .generateModel: "Model"
        case .generateEffort: "Effort"
        case .matchesStyle: "Match the repository's style"
        case .instructions: "Instructions"
        case .generateCommand: "Command"
        case .agentList: "Claude Code and Codex"
        case .hooks: "Hooks"
        case .showsMarks: "Show agents in the sidebar"
        case .marksLegend: "Marks"
        case .keepsCommitGraphCurrent: "Keep commit-graph files up to date"
        }
    }

    var help: String {
        switch self {
        case .terminal:
            "For Open in Terminal on a repository or a worktree."
        case .checksForUpdates:
            "Roga looks at roga.sh once a day, and the sidebar says when there's a new version. Nothing installs until you say so."
        case .downloadsUpdates:
            "A new version downloads in the background and installs when Roga quits. Restart to Update installs it straight away."
        case .animationSpeed:
            "How fast the house moves while git runs."
        case .fileLayout:
            "In the commit and changes panels. Also in the View menu."
        case .refsSort:
            "In the refs panel. Also in its sort menu and the View menu."
        case .foldsDescriptions:
            "The commit panel shows only a commit's first line, and clicking it shows the rest."
        case .fetchesByItself:
            "Roga runs git fetch for the repository on screen, at most once a minute, so that it can say how far your branch is from its upstream. It only moves remote branches, and it never asks for credentials."
        case .showsGenerateButton:
            "In the message box. ⌥⌘L writes a message too."
        case .generateAgent:
            "Your staged diff goes to the agent, and from there to its provider."
        case .generateModel:
            "Something fast is plenty for a commit message."
        case .matchesStyle:
            "Sends the last 20 commit subjects along with the diff."
        case .generateCommand:
            "It runs in the worktree's folder with its tools, hooks, plugins and MCP servers off, and without the repository's own agent settings, so it can't change anything. Agents are set up on the Agents page."
        case .showsMarks:
            "Marks each worktree an agent is working in, waiting in, or has finished in."
        case .theme, .gitProgram, .generateEffort, .instructions, .agentList, .hooks, .marksLegend:
            ""
        case .keepsCommitGraphCurrent:
            "Roga runs git commit-graph write in the background, so that large repositories open quickly. It writes to each repository's objects folder and never changes your git configuration."
        }
    }

    /// More words that find it, for what a block shows besides its title.
    private var keywords: [String] {
        switch self {
        case .terminal: ["Open in Terminal", "iTerm", "Ghostty", "Warp"]
        case .checksForUpdates: ["Sparkle", "version"]
        case .downloadsUpdates: ["install", "Restart to Update", "version"]
        case .theme: AppTheme.allCases.map(\.title) + ["Dark mode", "Light mode"]
        case .gitProgram: ["Look Again", "Choose Another", "program", "version", "PATH", "Xcode", "Command Line Tools", "Homebrew"]
        case .instructions: ["Reset to Roga's", "prompt"]
        case .agentList: ["Look Again", "Use", "program", "PATH"]
        case .hooks: ["Install", "Remove", "roga-hooks", "plugin", "Claude Code", "Codex"]
        case .marksLegend: ["Working", "Finished", "Waiting for you"]
        default: []
        }
    }

    func matches(_ query: String) -> Bool {
        ([title, help, group.title, group.page.title] + keywords).contains { $0.localizedStandardContains(query) }
    }
}

/// Roga's settings, as a sheet with a sidebar of pages, drawn like the design
/// canvas's Settings boards and Roga's dialogs rather than with the system's
/// lists and forms.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AgentProvider.self) private var agents
    /// It opens on the page it was on last, because going back is usually to
    /// change the same thing again, and on General the first time.
    @AppStorage(SettingsDestination.pageKey) private var page = SettingsPage.general
    /// The agent whose own page shows, under Agents, or nil for the page itself.
    @AppStorage(SettingsDestination.agentKey) private var agent: AgentKind?
    @State private var query = ""
    /// Whether the agents have been asked about their hooks since the sheet
    /// opened. Each check costs a run of each agent, and of `claude agents`
    /// after it, so it happens once a sheet rather than each time Agents shows.
    @State private var hasCheckedHooks = false

    @AppStorage(AppTheme.key) private var theme = AppTheme.system
    @AppStorage(UserDefaults.houseAnimationSpeedKey) private var speed = 1.0
    @AppStorage(FileListSettings.layout) private var fileLayout = FileLayout.list
    @AppStorage(RefsPanelSettings.sort) private var refsSort = RefsModel.Sort.name
    @AppStorage(CommitPanelSettings.collapsesBody) private var collapsesBody = false
    @AppStorage(UserDefaults.fetchesByItselfKey) private var fetchesByItself = true
    @AppStorage(UserDefaults.keepsCommitGraphCurrentKey) private var keepsCommitGraphCurrent = true

    /// The canvas's size, which leaves room for the pages still to come.
    static let size = CGSize(width: 880, height: 613)

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        HStack(spacing: 0) {
            // The sidebar runs the sheet's full height, with the search field
            // at its top, level with the page's title.
            SettingsSidebar(page: $page, agent: $agent, query: $query)
                .frame(width: 216)
                .frame(maxHeight: .infinity)
                .background(SettingsColors.sidebar)
            Rectangle()
                .fill(SettingsColors.hairline)
                .frame(width: 1)
            VStack(spacing: 0) {
                titleBar
                ScrollView(.vertical) {
                    content
                        .padding(EdgeInsets(top: 22, leading: 28, bottom: 28, trailing: 28))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(SettingsColors.surface)
        .font(.system(size: 13))
        // The menus of git's row and of an agent's program open over the
        // whole sheet.
        .programMenus()
        .presentationSizing(.fitted)
        .onChange(of: theme) { _, theme in
            theme.apply()
        }
        .onChange(of: destination.page == .agents, initial: true) { _, showsAgents in
            guard showsAgents, !hasCheckedHooks else { return }
            hasCheckedHooks = true
            agents.refreshHookStatus()
        }
    }

    /// What shows, from what's stored.
    private var destination: SettingsDestination {
        SettingsDestination(page: page, agent: agent)
    }

    /// Goes to a page or an agent's page, from a link on another page or from
    /// what search found.
    private func show(_ destination: SettingsDestination) {
        query = ""
        page = destination.page
        if case .agent(let kind) = destination { agent = kind } else { agent = nil }
    }

    /// The page's name, rather than "Settings", which the sheet already is,
    /// or the agent's on its own page.
    private var title: String {
        guard trimmedQuery.isEmpty else { return "Search" }
        if case .agent(let kind) = destination { return kind.name }
        return page.title
    }

    /// Whether the title bar has the back button, which an agent's page has
    /// before its title, as the canvas draws it.
    private var goesBack: Bool {
        guard trimmedQuery.isEmpty, case .agent = destination else { return false }
        return true
    }

    private var titleBar: some View {
        HStack(spacing: 4) {
            if goesBack {
                Button {
                    agent = nil
                } label: {
                    Icon.chevronLeft.image
                        .font(.system(size: 14))
                }
                .buttonStyle(.icon(size: 26))
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Agents")
                .accessibilityLabel("Back to Agents")
                .padding(.leading, -10)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button {
                dismiss()
            } label: {
                Icon.x.image
                    .font(.system(size: 13))
            }
            .buttonStyle(.icon(size: 26))
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 14))
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SettingsColors.hairline)
                .frame(height: 1)
        }
    }

    @ViewBuilder private var content: some View {
        if trimmedQuery.isEmpty {
            switch destination {
            case .agent(let kind):
                // Its settings are kept by kind, so another agent's page
                // starts afresh.
                AgentDetailPage(kind: kind)
                    .id(kind)
            case .page(.agents):
                AgentsPage(show: show)
            case .page(let page):
                VStack(alignment: .leading, spacing: 30) {
                    ForEach(SettingsGroup.allCases.filter { $0.page == page }, id: \.self) { group in
                        section(group, items: group.items, namesPage: false)
                    }
                }
            }
        } else {
            let found = SettingsGroup.allCases.compactMap { group -> (SettingsGroup, [SettingsItem])? in
                let items = group.items.filter { $0.matches(trimmedQuery) }
                return items.isEmpty ? nil : (group, items)
            }
            if found.isEmpty {
                Text("No settings match “\(trimmedQuery)”.")
                    .foregroundStyle(SettingsColors.note)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 30) {
                    ForEach(found, id: \.0) { group, items in
                        section(group, items: items, namesPage: true)
                    }
                }
            }
        }
    }

    /// A group's section, on its page or among what search found. The
    /// General, Commit and Agents pages draw their own groups.
    @ViewBuilder private func section(_ group: SettingsGroup, items: [SettingsItem], namesPage: Bool) -> some View {
        switch group {
        case .openIn, .updates:
            GeneralSection(group: group, items: items, namesPage: namesPage)
        case .installation:
            GitProgramSection(items: items, namesPage: namesPage)
        case .generate:
            CommitSection(items: items, namesPage: namesPage, show: show)
        case .commandLineAgents:
            AgentListSection(items: items, namesPage: namesPage, show: show)
        case .workingStatus:
            WorkingStatusSection(items: items, namesPage: namesPage)
        case .interface, .motion, .lists, .fetching, .largeRepositories:
            SettingsSection(title: group.title) {
                if namesPage {
                    Text(group.page.title)
                        .foregroundStyle(SettingsColors.note)
                }
            } content: {
                if items.contains(.animationSpeed) {
                    SettingsBlock {
                        HouseAnimations()
                    }
                }
                ForEach(items, id: \.self) { item in
                    row(item)
                }
            }
        }
    }

    @ViewBuilder private func row(_ item: SettingsItem) -> some View {
        SettingsRow(title: item.title, help: item.help) {
            switch item {
            case .theme:
                SettingsSegments(selection: $theme, options: AppTheme.allCases.map { ($0, $0.title) }, icon: \.icon)
            case .animationSpeed:
                SettingsSlider(value: $speed, range: HouseAnimationView.speeds, step: 0.25) { "\($0.formatted())×" }
            case .fileLayout:
                SettingsSegments(selection: $fileLayout, options: [(.list, "List"), (.tree, "Tree")])
            case .refsSort:
                SettingsSegments(selection: $refsSort, options: [(.name, "Name"), (.date, "Date")])
            case .foldsDescriptions:
                Toggle(item.title, isOn: $collapsesBody)
                    .toggleStyle(.settings)
            case .fetchesByItself:
                Toggle(item.title, isOn: $fetchesByItself)
                    .toggleStyle(.settings)
            case .keepsCommitGraphCurrent:
                Toggle(item.title, isOn: $keepsCommitGraphCurrent)
                    .toggleStyle(.settings)
            case .terminal, .checksForUpdates, .downloadsUpdates, .gitProgram, .showsGenerateButton, .generateAgent, .generateModel,
                 .generateEffort, .matchesStyle, .instructions, .generateCommand, .agentList, .hooks, .showsMarks, .marksLegend:
                // The General, Git, Commit and Agents pages draw their own.
                EmptyView()
            }
        }
    }
}

/// The search field, the pages, and Roga's version at the bottom.
private struct SettingsSidebar: View {
    @Binding var page: SettingsPage
    /// The agent whose page shows. Choosing a page, Agents included, leaves it.
    @Binding var agent: AgentKind?
    @Binding var query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            search
                .padding(.bottom, 12)
            ForEach(Array(SettingsPage.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Rectangle()
                        .fill(SettingsColors.hairline)
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                ForEach(group) { item in
                    PageButton(page: item, isSelected: query.isEmpty && page == item) {
                        page = item
                        agent = nil
                        query = ""
                    }
                }
            }
            Spacer(minLength: 0)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("Roga \(version)")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsColors.note)
                    .padding(EdgeInsets(top: 12, leading: 10, bottom: 2, trailing: 10))
            }
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 12, trailing: 12))
    }

    private var search: some View {
        HStack(spacing: 8) {
            Icon.search.image
                .font(.system(size: 13))
                .foregroundStyle(SettingsColors.note)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search settings")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(SettingsColors.line, lineWidth: 1)
        }
    }
}

/// A page in the sidebar: soft gray while it shows, and lighter while the
/// pointer is over it.
private struct PageButton: View {
    let page: SettingsPage
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                page.icon.image
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.primary : SettingsColors.note)
                    .frame(width: 16)
                Text(page.title)
                    .fontWeight(isSelected ? .medium : .regular)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(
                isSelected ? SettingsColors.selectedPage : isHovering ? SettingsColors.hover : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The house's four animations on a gray card, which move as the speed changes.
private struct HouseAnimations: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(HouseAnimation.allCases) { animation in
                VStack(spacing: 6) {
                    HouseAnimationView(animation: animation, height: 46)
                    Text(animation.title)
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsColors.note)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 8, bottom: 10, trailing: 8))
        .background(SettingsColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The house's animations: Push, Tug of War, Heave and Waddle")
    }
}
