import AgentEngine
import IconUI
import SwiftUI
import ThemeUI

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

/// The pages of Settings, in the order its sidebar lists them. Commit folded
/// into Git (decision 89), and so did Advanced (decision 90), so a stored
/// `commit` or `advanced` opens General.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case appearance
    case git
    case agents

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .git: "Git"
        case .agents: "Agents"
        }
    }

    var icon: Icon {
        switch self {
        case .general: .slidersHorizontal
        case .appearance: .palette
        case .git: .branch
        case .agents: .squareTerminal
        }
    }

    /// The sidebar's groups, with a line between each, as on the canvas.
    static let groups: [[SettingsPage]] = [[.general, .appearance], [.git], [.agents]]
}

/// A heading on a page, and the settings under it, in the order the page
/// shows them.
enum SettingsGroup: CaseIterable {
    case openIn
    case updates
    case interface
    case motion
    case lists
    case installation
    case fetching
    case largeRepositories
    case generate
    case agents
    case agentStatus

    var title: String {
        switch self {
        case .openIn: "Open in"
        case .updates: "Updates"
        case .interface: "Interface"
        case .motion: "Motion"
        case .lists: "Lists"
        case .installation: "Installation"
        case .fetching: "Fetching"
        case .largeRepositories: "Large repositories"
        case .generate: "Commit messages"
        case .agents: "Agents"
        case .agentStatus: "Status"
        }
    }

    var page: SettingsPage {
        switch self {
        case .openIn, .updates: .general
        case .interface, .motion, .lists: .appearance
        case .installation, .fetching, .largeRepositories, .generate: .git
        case .agents, .agentStatus: .agents
        }
    }

    /// What the whole group is about, under its heading on its page.
    var description: String? {
        switch self {
        case .installation:
            "Requires Git \(SetupWords.minimumGit) or later."
        case .agents:
            "Generate, Resolve and Fix run the default agent with its tools off, and send what they need to its provider."
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

    /// Whether Settings shows it, on its page and when searching. Motion is
    /// left out for now, with the house's animations and their speed, which
    /// stays normal (`HouseAnimationView.offersSpeed`). Its code stays, for
    /// when it comes back.
    var isShown: Bool {
        self != .motion || HouseAnimationView.offersSpeed
    }

    /// The groups Settings shows, in order, with what's about agents only
    /// while Roga uses them (decision 89).
    static func shown(usesAgents: Bool = true) -> [SettingsGroup] {
        allCases.filter { $0.isShown && (usesAgents || ($0 != .generate && $0 != .agentStatus)) }
    }

    /// What a search finds: each group Settings shows that has a setting
    /// whose words match, with those settings. While agents are off, Use
    /// agents is all it finds about them.
    static func found(_ query: String, usesAgents: Bool = true) -> [(group: SettingsGroup, items: [SettingsItem])] {
        shown(usesAgents: usesAgents).compactMap { group in
            let items = group.items.filter { $0.matches(query) && (usesAgents || $0.group != .agents || $0 == .usesAgents) }
            return items.isEmpty ? nil : (group, items)
        }
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
    case colors
    case codeFont
    case animationSpeed
    case fileLayout
    case refsSort
    case foldsDescriptions
    case gitProgram
    case fetchesByItself
    case showsGenerateButton
    case matchesStyle
    case instructions
    case usesAgents
    case agentList
    case defaultAgent
    case hooks
    case marksLegend
    case keepsCommitGraphCurrent

    var group: SettingsGroup {
        switch self {
        case .terminal: .openIn
        case .checksForUpdates, .downloadsUpdates: .updates
        case .theme, .colors, .codeFont: .interface
        case .animationSpeed: .motion
        case .fileLayout, .refsSort, .foldsDescriptions: .lists
        case .gitProgram: .installation
        case .fetchesByItself: .fetching
        case .showsGenerateButton, .matchesStyle, .instructions: .generate
        case .usesAgents, .agentList, .defaultAgent: .agents
        case .hooks, .marksLegend: .agentStatus
        case .keepsCommitGraphCurrent: .largeRepositories
        }
    }

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .checksForUpdates: "Check for updates automatically"
        case .downloadsUpdates: "Download updates automatically"
        case .theme: "Theme"
        case .colors: "Colors"
        case .codeFont: "Code font"
        case .animationSpeed: "Animation speed"
        case .fileLayout: "File layout"
        case .refsSort: "Branch sorting"
        case .foldsDescriptions: "Fold commit descriptions"
        case .gitProgram: "Git"
        case .fetchesByItself: "Fetch when Roga becomes active"
        case .showsGenerateButton: "Show Generate button"
        case .matchesStyle: "Match repository commit style"
        case .instructions: "Custom instructions"
        case .usesAgents: "Use agents"
        case .agentList: "Claude Code, Codex and custom agents"
        case .defaultAgent: "Default agent"
        case .hooks: "Hooks"
        case .marksLegend: "Status indicators"
        case .keepsCommitGraphCurrent: "Keep commit-graph files up to date"
        }
    }

    /// The gray words under the name, which only a setting whose name
    /// doesn't say it all has: a side effect, what's sent somewhere, or a
    /// requirement that isn't plain (decision 89).
    var help: String {
        switch self {
        case .checksForUpdates:
            "Check roga.sh daily and show available updates in the sidebar."
        case .downloadsUpdates:
            "Installs when Roga quits, or at once with Restart to Update."
        case .colors:
            "For the graph, branches, diffs and commands."
        case .animationSpeed:
            "House animation speed during Git operations."
        case .fetchesByItself:
            "At most once a minute. Only remote-tracking branches are updated."
        case .matchesStyle:
            "Sends the last 20 commit subjects with the diff."
        case .usesAgents:
            "Generate commit messages, resolve conflicts and fix Git errors with a coding agent, and see what your agents are doing in the sidebar."
        case .keepsCommitGraphCurrent:
            "Runs git commit-graph write in the background, without changing Git configuration."
        case .terminal, .theme, .codeFont, .fileLayout, .refsSort, .foldsDescriptions, .gitProgram, .showsGenerateButton,
             .instructions, .agentList, .defaultAgent, .hooks, .marksLegend:
            ""
        }
    }

    /// More words that find it, for what a block shows besides its title.
    private var keywords: [String] {
        switch self {
        case .terminal: ["Open in Terminal", "iTerm", "Ghostty", "Warp", "Default app"]
        case .checksForUpdates: ["Sparkle", "version"]
        case .downloadsUpdates: ["install", "Restart to Update", "version"]
        case .theme: AppTheme.allCases.map(\.title) + ["Dark mode", "Light mode"]
        case .colors: ColorTheme.allCases.map(\.title) + ["Color theme", "Palette", "Graph"]
        case .codeFont: [CodeFont.systemFamilyTitle, "Monospaced", "Typeface", "Diff", "Font size", "Text size", "Points"]
        case .fileLayout: ["List", "Tree", "Changes"]
        case .refsSort: ["Name", "Date", "Refs", "Branches"]
        case .foldsDescriptions: ["Collapse", "Expand", "Subject", "Body"]
        case .showsGenerateButton: ["Generate", "⌥⌘L", "message editor"]
        case .gitProgram: ["Rescan", "Choose another", "executable", "program", "version", "PATH", "Xcode", "Command Line Tools", "Homebrew"]
        case .instructions: ["Restore Defaults", "prompt", "commit message"]
        case .usesAgents: ["Claude Code", "Codex", "Generate", "Resolve", "Fix", "Turn off", "sidebar"]
        case .agentList: ["Rescan", "executable", "program", "PATH", "model", "effort", "Run Test", "Add Custom Agent", "command", "Ollama", "local model"]
        case .defaultAgent: ["Claude Code", "Codex", "Generate", "Resolve", "Fix", "conflicts", "commit message"]
        case .hooks: ["Install", "Remove", "roga-hooks", "plugin", "Claude Code", "Codex", "Agent status", "sidebar"]
        case .marksLegend: ["Working", "Finished", "Waiting", "approval", "response", "sidebar"]
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
    @AppStorage(SettingsDestination.agentKey) private var agent: AgentID?
    @State private var query = ""
    /// Whether the agents have been asked about their hooks since the sheet
    /// opened. Each check costs a run of each agent, and of `claude agents`
    /// after it, so it happens once a sheet rather than each time Agents shows.
    @State private var hasCheckedHooks = false

    @AppStorage(AppTheme.key) private var theme = AppTheme.system
    @AppStorage(ColorTheme.key) private var colorTheme = ColorTheme.monokai
    /// The code font's family, or nil for the system's (decision 73).
    @AppStorage(CodeFont.familyKey) private var codeFontFamily: String?
    @AppStorage(CodeFont.sizeKey) private var codeFontSize = CodeFont.defaultSize
    /// The families to choose the code font from, which are looked up as the
    /// sheet opens, so that a font installed since then is among them.
    @State private var codeFontFamilies: [String] = []
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
        .onChange(of: colorTheme) { _, colorTheme in
            colorTheme.use()
        }
        // What's stored is read back, since that's where a family that isn't
        // installed gives way to the system's font.
        .onChange(of: codeFontFamily) {
            CodeFont.stored().use()
        }
        .onChange(of: codeFontSize) {
            CodeFont.stored().use()
        }
        .onAppear {
            codeFontFamilies = CodeFont.installedFamilies()
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
        if case .agent(let id) = destination { agent = id } else { agent = nil }
    }

    /// The page's name, rather than "Settings", which the sheet already is,
    /// or the agent's on its own page.
    private var title: String {
        guard trimmedQuery.isEmpty else { return "Search" }
        if case .agent(let id) = destination, let named = agents.named(id) { return named.name }
        return page.title
    }

    /// Whether the title bar has the back button, which an agent's page has
    /// before its title, as the canvas draws it.
    private var goesBack: Bool {
        guard trimmedQuery.isEmpty, case .agent(let id) = destination, agents.named(id) != nil else { return false }
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
            case .agent(.known(let kind)) where agents.usesAgents:
                // Its settings are kept by kind, so another agent's page
                // starts afresh.
                AgentDetailPage(kind: kind)
                    .id(kind)
            case .agent(.custom(let id)) where agents.usesAgents && agents.customAgent(id) != nil:
                if let custom = agents.customAgent(id) {
                    CustomAgentPage(custom: custom) { agent = nil }
                        .id(id)
                }
            case .agent, .page(.agents):
                // A custom agent that's gone, or an agent's page while agents
                // are off, is the Agents page.
                AgentsPage(show: show)
            case .page(let page):
                VStack(alignment: .leading, spacing: 30) {
                    ForEach(SettingsGroup.shown(usesAgents: agents.usesAgents).filter { $0.page == page }, id: \.self) { group in
                        section(group, items: group.items, namesPage: false)
                    }
                }
            }
        } else {
            let found = SettingsGroup.found(trimmedQuery, usesAgents: agents.usesAgents)
            if found.isEmpty {
                Text("No settings match “\(trimmedQuery)”.")
                    .foregroundStyle(SettingsColors.note)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 30) {
                    ForEach(found, id: \.group) { group, items in
                        section(group, items: items, namesPage: true)
                    }
                }
            }
        }
    }

    /// A group's section, on its page or among what search found. The
    /// General and Agents pages, and Git's installation and commit messages,
    /// draw their own groups.
    @ViewBuilder private func section(_ group: SettingsGroup, items: [SettingsItem], namesPage: Bool) -> some View {
        switch group {
        case .openIn, .updates:
            GeneralSection(group: group, items: items, namesPage: namesPage)
        case .installation:
            GitProgramSection(items: items, namesPage: namesPage)
        case .generate:
            CommitSection(items: items, namesPage: namesPage)
        case .agents:
            AgentListSection(items: items, namesPage: namesPage, show: show)
        case .agentStatus:
            AgentStatusSection(items: items, namesPage: namesPage)
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
                if group == .interface {
                    // The preview goes between the rows it follows: Theme and
                    // Colors above it, and the code font below (decision 73).
                    // Its border sets it apart, so no line comes between it and
                    // the row on either side.
                    let above = items.filter { $0 != .codeFont }
                    let showsCodeFont = items.contains(.codeFont)
                    ForEach(above.dropLast(), id: \.self) { row($0) }
                    VStack(spacing: 0) {
                        if let last = above.last { row(last) }
                        ThemePreview()
                            .padding(EdgeInsets(top: above.isEmpty ? 8 : 4, leading: 0, bottom: showsCodeFont ? 4 : 12, trailing: 0))
                        if showsCodeFont { codeFontRow }
                    }
                } else {
                    ForEach(items, id: \.self) { row($0) }
                }
            }
        }
    }

    /// The code font's choices: the system's font first, then each installed
    /// family with a fixed width. The family chosen is among them even before
    /// they're looked up, and when it was stored from outside Settings.
    private var codeFontOptions: [(value: String?, title: String)] {
        var families = codeFontFamilies
        if let chosen = shownCodeFontFamily.wrappedValue, !families.contains(chosen) {
            families.append(chosen)
            families.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return [(nil, CodeFont.systemFamilyTitle)] + families.map { ($0, $0) }
    }

    /// The family chosen, as the popup shows it. One that's stored but isn't
    /// installed any more shows as the system's font, which is what code is
    /// drawn in then.
    private var shownCodeFontFamily: Binding<String?> {
        Binding {
            codeFontFamily.flatMap { CodeFont.isInstalled($0) ? $0 : nil }
        } set: { family in
            codeFontFamily = family
        }
    }

    /// The size chosen, as the popup shows it and as code is drawn: one stored
    /// from outside Settings is brought within the sizes Roga uses.
    private var shownCodeFontSize: Binding<Double> {
        Binding {
            CodeFont.usable(size: codeFontSize)
        } set: { size in
            codeFontSize = size
        }
    }

    /// The sizes to choose from, with the one chosen among them when it's a
    /// size in between that was stored from outside Settings.
    private var codeFontSizeOptions: [(value: Double, title: String)] {
        var sizes = CodeFont.sizes
        let chosen = shownCodeFontSize.wrappedValue
        if !sizes.contains(chosen) {
            sizes.append(chosen)
            sizes.sort()
        }
        return sizes.map { ($0, "\($0.formatted()) pt") }
    }

    /// The code font's family and its size on one row, as a font's are in the
    /// Mac's own settings, which also keeps the heading after it in view. Each
    /// menu marks what Roga starts with, and VoiceOver calls each by what it
    /// chooses, since the row's name is only the first one's.
    private var codeFontRow: some View {
        SettingsRow(title: SettingsItem.codeFont.title, help: SettingsItem.codeFont.help, namesControl: false) {
            HStack(spacing: 0) {
                SettingsPopup(
                    selection: shownCodeFontFamily,
                    options: codeFontOptions,
                    detail: { $0 == nil ? "Default" : nil },
                    detailInMenuOnly: true
                )
                .accessibilityLabel("Code font")
                SettingsPopup(
                    selection: shownCodeFontSize,
                    options: codeFontSizeOptions,
                    detail: { $0 == CodeFont.defaultSize ? "Default" : nil },
                    detailInMenuOnly: true
                )
                .accessibilityLabel("Code font size")
            }
        }
    }

    @ViewBuilder private func row(_ item: SettingsItem) -> some View {
        SettingsRow(title: item.title, help: item.help) {
            switch item {
            case .theme:
                SettingsSegments(selection: $theme, options: AppTheme.allCases.map { ($0, $0.title) }, icon: \.icon)
            case .colors:
                SettingsSegments(selection: $colorTheme, options: ColorTheme.allCases.map { ($0, $0.title) })
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
            case .terminal, .checksForUpdates, .downloadsUpdates, .gitProgram, .showsGenerateButton, .matchesStyle, .instructions,
                 .usesAgents, .agentList, .defaultAgent, .hooks, .marksLegend, .codeFont:
                // The General, Git and Agents pages draw their own, and the
                // code font's row has two controls.
                EmptyView()
            }
        }
    }
}

/// The search field, the pages, and Roga's version at the bottom.
private struct SettingsSidebar: View {
    @Binding var page: SettingsPage
    /// The agent whose page shows. Choosing a page, Agents included, leaves it.
    @Binding var agent: AgentID?
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

/// The house's animations on a gray card, which move as the speed changes.
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
        .accessibilityLabel("The house's animations: Push, Tug of War, Heave, Waddle and Run")
    }
}
