import AgentEngine
import AgentHooks
import Foundation
import GitCore
import IconUI
import SwiftUI

/// Settings › Agents (decision 89): Use agents, which turns everything about
/// agents on or off, and while it's on, the agents Roga found and the ones
/// someone added as commands, the default agent that Generate, Resolve and
/// Fix run, and Status, the hooks through which Claude Code and Codex tell
/// Roga what they're doing, for the sidebar's marks.
struct AgentsPage: View {
    let show: (SettingsDestination) -> Void
    @Environment(AgentProvider.self) private var agents

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            // With agents off it's the page's only row, with no heading over
            // it, and nothing else about agents shows.
            UsesAgentsRow()
            if agents.usesAgents {
                AgentListSection(show: show)
                AgentStatusSection()
            }
        }
    }
}

/// Use agents, the one switch for everything Roga does with agents.
struct UsesAgentsRow: View {
    @Environment(AgentProvider.self) private var agents

    var body: some View {
        let item = SettingsItem.usesAgents
        SettingsRow(title: item.title, help: item.help) {
            Toggle(item.title, isOn: Binding { agents.usesAgents } set: { agents.setUsesAgents($0) })
                .toggleStyle(.settings)
        }
    }
}

/// Look Again for the agents, which finds them again and checks their hooks.
struct RescanButton: View {
    @Environment(AgentProvider.self) private var agents

    /// Its icon: Lucide's rotate-cw, one arrow going round, as the canvas
    /// draws it, rather than refresh-cw's pair.
    static let icon = Icon.rotateCw

    var body: some View {
        Button {
            // Looking again starts afresh, so what failed before goes from
            // the hooks' rows.
            agents.lookAgain()
        } label: {
            HStack(spacing: 6) {
                Self.icon.image
                    .font(.system(size: 11))
                Text("Rescan")
            }
        }
        .buttonStyle(.settings(small: true))
        .disabled(agents.isLooking)
        .help("Scan for Claude Code and Codex installations, and check their hooks")
    }
}

/// The agents: Claude Code and Codex, whether or not Roga found them, then
/// the custom ones, each going to its own page, and Add Custom Agent… under
/// them in the accent. The default agent comes after them. Search shows it too, with Use
/// agents among what it found.
struct AgentListSection: View {
    var items = SettingsGroup.agents.items
    var namesPage = false
    let show: (SettingsDestination) -> Void
    @Environment(AgentProvider.self) private var agents
    @State private var isAdding = false

    var body: some View {
        SettingsSection(title: SettingsGroup.agents.title, description: namesPage ? nil : SettingsGroup.agents.styledDescription) {
            if namesPage {
                Text(SettingsPage.agents.title)
                    .foregroundStyle(SettingsColors.note)
            } else {
                Spacer(minLength: 0)
                RescanButton()
            }
        } content: {
            // On the page, Use agents is above the heading.
            if namesPage, items.contains(.usesAgents) {
                UsesAgentsRow()
            }
            if agents.usesAgents {
                if items.contains(.agentList) {
                    SettingsBlock {
                        // Add Custom Agent… is under the list at its right
                        // edge, in the accent, as New SSH Key… is under the
                        // Key field (decision 108).
                        VStack(alignment: .trailing, spacing: 8) {
                            SettingsList {
                                ForEach(AgentKind.allCases) { kind in
                                    AgentRow(kind: kind, show: show)
                                }
                                ForEach(agents.customAgents) { custom in
                                    CustomAgentRow(custom: custom, show: show)
                                }
                            }
                            Button("Add Custom Agent…") { isAdding = true }
                                .buttonStyle(.contextual)
                                .fixedSize()
                                .help("Add an agent that Roga runs with a command")
                        }
                    }
                }
                if items.contains(.defaultAgent) {
                    SettingsRow(title: SettingsItem.defaultAgent.title, help: nil) {
                        SettingsSelect(
                            selection: Binding { agents.defaultAgent } set: { if let id = $0 { agents.setDefaultAgent(id) } },
                            options: AgentSummaries.defaultOptions(agents),
                            emptyTitle: AgentSummaries.noAgentTitle(agents)
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            AddCustomAgentDialog { custom in
                // A new agent's page isn't where someone is going, so the
                // list stays, with it in.
                _ = custom
            }
            .environment(agents)
        }
    }
}

/// Claude Code or Codex in the list: its name, then where its program is, or
/// why there's none, and the chevron to its page. The whole row goes there.
private struct AgentRow: View {
    let kind: AgentKind
    let show: (SettingsDestination) -> Void
    @Environment(AgentProvider.self) private var agents

    var body: some View {
        let line = AgentSummaries.programLine(agents.lookups[kind])
        AgentListRow(name: kind.name, isDimmed: agents.installation(kind) == nil, spoken: line.text) {
            show(.agent(.known(kind)))
        } detail: {
            ProgramLineText(line: line)
        }
    }
}

/// A custom agent in the list: its name with a Custom tag, then its command
/// in the code font, and the chevron to its page.
private struct CustomAgentRow: View {
    let custom: CustomAgent
    let show: (SettingsDestination) -> Void

    var body: some View {
        AgentListRow(name: custom.shownName, isCustom: true, spoken: custom.command) {
            show(.agent(.custom(custom.id)))
        } detail: {
            ProgramLineText(line: ProgramLine(text: custom.command, tone: .path))
        }
    }
}

/// A row of the agents' list, which goes to the agent's page.
private struct AgentListRow<Detail: View>: View {
    let name: String
    var isDimmed = false
    var isCustom = false
    /// What the second line says, for VoiceOver.
    let spoken: String
    let action: () -> Void
    @ViewBuilder var detail: Detail

    var body: some View {
        Button(action: action) {
            HStack(alignment: .settingsFirstLine, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        AgentName(name: name, isDimmed: isDimmed)
                        if isCustom {
                            CustomTag()
                        }
                    }
                    detail
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Icon.chevronRight.image
                    .font(.system(size: 14))
                    .foregroundStyle(SettingsColors.note)
                    .frame(width: 24, height: 24)
                    .alignmentGuide(.settingsFirstLine) { $0[VerticalAlignment.center] }
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 12))
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(name) Settings")
        .accessibilityLabel(isCustom ? "\(name), custom agent" : name)
        .accessibilityValue(spoken)
        .accessibilityHint("Shows \(name)'s settings")
    }
}

/// The small gray tag after a custom agent's name.
private struct CustomTag: View {
    var body: some View {
        Text("Custom")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(SettingsColors.note)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(SettingsColors.card, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Status: the hooks for Claude Code and Codex, why the sidebar can't show
/// marks when it can't, and what each mark means. A custom agent has no
/// hooks, so it isn't here.
struct AgentStatusSection: View {
    var items = SettingsGroup.agentStatus.items
    var namesPage = false
    @Environment(AgentProvider.self) private var agents
    @Environment(AgentMonitor.self) private var monitor
    @Environment(RepositoryList.self) private var list
    @State private var dialog: HooksDialog.Request?
    @State private var places = HeardPlaces()

    var body: some View {
        SettingsSection(title: SettingsGroup.agentStatus.title) {
            if namesPage {
                Text(SettingsPage.agents.title)
                    .foregroundStyle(SettingsColors.note)
            }
        } content: {
            ForEach(items, id: \.self) { item in
                row(item)
            }
        }
        .sheet(item: $dialog) { request in
            HooksDialog(request: request)
                .environment(agents)
        }
    }

    @ViewBuilder private func row(_ item: SettingsItem) -> some View {
        switch item {
        case .hooks:
            SettingsBlock {
                // It redraws each minute for "Last heard from 2 minutes ago".
                // The time it gives is the minute's start, which would say a
                // minute less, so the line asks for the time itself.
                TimelineView(.everyMinute) { _ in
                    SettingsList {
                        ForEach(AgentKind.allCases) { kind in
                            HookRow(
                                kind: kind,
                                line: AgentSummaries.hookLine(kind, agents: agents, heard: heard(kind), now: .now) {
                                    places.place(of: $0, in: list)
                                },
                                open: open
                            )
                        }
                    }
                }
            }
            if let notice = AgentSummaries.listeningNotice(monitor.listening) {
                SettingsBlock {
                    SettingsNotice(text: notice) {
                        Button("Try Again") {
                            monitor.start(agents: agents)
                        }
                        .buttonStyle(.settings(small: true))
                    }
                }
            }
        case .marksLegend:
            SettingsBlock {
                MarksPreview()
            }
        default:
            EmptyView()
        }
    }

    private func heard(_ kind: AgentKind) -> AgentProvider.Heard? {
        AgentHost(rawValue: kind.rawValue).flatMap { monitor.lastHeard[$0] }
    }

    private func open(_ kind: AgentKind, _ action: HooksDialog.Action) {
        dialog = HooksDialog.Request(kind: kind, action: action, offers: HooksDialog.otherAgent(for: kind, action: action, agents: agents))
    }
}

/// An agent's hooks, in the list on the Agents page: whether they're
/// installed and when Roga last heard from them, the button that installs or
/// removes them, beside the agent's name so that it stays put as the words
/// under the name change, and what went wrong, in red.
private struct HookRow: View {
    let kind: AgentKind
    let line: HookLine
    let open: (AgentKind, HooksDialog.Action) -> Void

    var body: some View {
        HStack(alignment: .settingsFirstLine, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                AgentName(name: kind.name, isDimmed: line.button == nil)
                HookLineText(line: line, size: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let button = line.button {
                Button(button.title) {
                    open(kind, button.action)
                }
                .buttonStyle(.settings(button.action == .install ? .primary : .secondary, small: true))
                .disabled(!button.isEnabled)
                // The page has a button for each agent, so VoiceOver's list
                // of buttons needs the agent's name in each.
                .accessibilityLabel(button.spokenTitle(kind))
                .alignmentGuide(.settingsFirstLine) { $0[VerticalAlignment.center] }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 12))
        .frame(minHeight: 58)
    }
}

/// What a hook's line says, with "Installed" in green when it starts with
/// it, then why Install can't work and what failed.
struct HookLineText: View {
    let line: HookLine
    var size: CGFloat = 12.5

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            status
                .fixedSize(horizontal: false, vertical: true)
            if let note = line.note {
                Text(note)
                    .foregroundStyle(AgentColors.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(line.problems, id: \.self) { problem in
                Text(problem)
                    .foregroundStyle(SettingsColors.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: size))
        .lineSpacing(3)
    }

    private var status: Text {
        switch line.tone {
        case .plain:
            Text(line.text).foregroundStyle(SettingsColors.note)
        case .warn:
            Text(line.text).foregroundStyle(AgentColors.warn)
        case .installed:
            Text("\(Text(HookLine.installed).fontWeight(.medium).foregroundStyle(AgentColors.ok))\(Text(line.text.dropFirst(HookLine.installed.count)).foregroundStyle(SettingsColors.note))")
        }
    }
}

/// The second line of an agent's row: where its program is and which
/// version, in the code font, or why there's none in words.
private struct ProgramLineText: View {
    let line: ProgramLine

    var body: some View {
        switch line.tone {
        case .path:
            Text(line.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(SettingsColors.note)
                .lineLimit(1)
                .truncationMode(.middle)
        case .plain:
            Text(line.text)
                .font(.system(size: 12))
                .foregroundStyle(SettingsColors.note)
                .fixedSize(horizontal: false, vertical: true)
        case .warn:
            Text(line.text)
                .font(.system(size: 12))
                .foregroundStyle(AgentColors.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An agent's name at the top of its row, which is gray while Roga can't use
/// the agent, because Roga didn't find it. The row's controls sit on the
/// middle of its line.
private struct AgentName: View {
    let name: String
    var isDimmed = false

    var body: some View {
        Text(name)
            .fontWeight(.medium)
            .foregroundStyle(isDimmed ? SettingsColors.note : .primary)
            .alignmentGuide(.settingsFirstLine) { $0[VerticalAlignment.center] }
    }
}

// MARK: What the rows say

/// The second line of an agent's row on the Agents page.
struct ProgramLine: Equatable {
    enum Tone: Equatable {
        /// A program's path and version, in the code font.
        case path
        case plain
        /// Why Roga can't use what it found, in amber.
        case warn
    }

    var text: String
    var tone: Tone
}

/// What an agent's hooks line says: its status, the button beside it, why
/// Install can't work, and what went wrong.
struct HookLine: Equatable {
    enum Tone: Equatable {
        case plain
        /// It starts with "Installed", which is green.
        case installed
        /// Something to do something about, in amber.
        case warn
    }

    struct Offer: Equatable {
        var action: HooksDialog.Action
        var title: String
        var isEnabled: Bool
        /// Whether the action is under way, so the button says it's working.
        var isWorking = false

        /// What VoiceOver calls the button, which names the agent, since the
        /// visible title leaves that to the row: "Install Roga's hooks in
        /// Claude Code", or "Installing Roga's hooks in Claude Code" while it
        /// runs.
        func spokenTitle(_ kind: AgentKind) -> String {
            switch (action, isWorking) {
            case (.install, false): "Install Roga's hooks in \(kind.name)"
            case (.install, true): "Installing Roga's hooks in \(kind.name)"
            case (.remove, false): "Remove Roga's hooks from \(kind.name)"
            case (.remove, true): "Removing Roga's hooks from \(kind.name)"
            }
        }
    }

    var tone: Tone
    var text: String
    var button: Offer?
    /// Why Install can't work in this copy of Roga, in amber.
    var note: String?
    /// What failed, in the agent's or the system's own words, in red.
    var problems: [String] = []

    /// All of it as sentences, for VoiceOver to read once, as the row's value.
    var spoken: String {
        ([text] + [note].compactMap(\.self) + problems).map(AgentSummaries.sentence).joined(separator: " ")
    }

    static let installed = "Installed"
}

/// What Settings says about agents, from the provider's and the monitor's
/// state, kept apart from the views so that tests can check every case.
enum AgentSummaries {
    /// Where an agent's program is, or why there's none Roga can use.
    static func programLine(_ lookup: AgentLookup?) -> ProgramLine {
        switch lookup {
        case nil:
            ProgramLine(text: "Searching…", tone: .plain)
        case .found(let installation)?:
            ProgramLine(text: "\(abbreviated(installation.executable)) · \(installation.version)", tone: .path)
        case .notFound?:
            ProgramLine(text: "Not found in your login shell's PATH.", tone: .plain)
        case .unusable(let skipped)?:
            ProgramLine(text: sentence(skipped.map(\.description).joined(separator: "; ")), tone: .warn)
        case .configuredMissing(let path)?:
            ProgramLine(text: "Custom executable not found or cannot be run: \(abbreviated(path)).", tone: .warn)
        case .configuredUnusable(let skipped)?:
            ProgramLine(text: sentence(skipped.description), tone: .warn)
        }
    }

    /// What Default agent offers: every agent Roga can run, custom ones too.
    /// There's no None, since turning agents off is Use agents.
    static func defaultOptions(_ agents: AgentProvider) -> [(value: AgentID?, title: String)] {
        agents.availableAgents.compactMap { id in agents.named(id).map { (value: id, title: $0.name) } }
    }

    /// What Default agent says while it has nothing to offer.
    static func noAgentTitle(_ agents: AgentProvider) -> String {
        agents.isLooking ? "Searching…" : "None found"
    }

    /// What an agent's hooks line says and offers. Install needs the agent
    /// found, and the `roga` helper inside this copy of Roga for its hooks
    /// to run. While Install or Remove runs, its button says so and waits.
    /// How it last failed shows for as long as the provider keeps it, which
    /// is while it still applies.
    static func hookLine(
        _ kind: AgentKind,
        agents: AgentProvider,
        heard: AgentProvider.Heard?,
        now: Date,
        place: (String) -> String
    ) -> HookLine {
        let failure = agents.hookWork[kind]?.failure
        let filesError = agents.pluginFilesError.map { [$0] } ?? []

        guard case .found? = agents.lookups[kind] else {
            // What failed still stands while Roga looks for the agent again.
            // Once it can't find the agent, the line says what it needs
            // instead.
            let isLooking = agents.lookups[kind] == nil
            let text = isLooking ? "Checking…" : "Install or select \(kind.name) to enable hook installation."
            return HookLine(tone: .plain, text: text, problems: (isLooking ? failure.map { [$0] } ?? [] : []) + filesError)
        }

        let tone: HookLine.Tone
        let text: String
        switch agents.hookStatus[kind] {
        case nil:
            (tone, text) = (.plain, "Checking…")
        case .notInstalled?:
            let trust = kind == .codex ? " Codex asks you to trust a new hook the first time it runs." : ""
            (tone, text) = (.plain, "Not installed.\(trust)")
        case .installed?:
            let last = heardSentence(heard, now: now, place: place).map { " " + $0 } ?? ""
            (tone, text) = (.installed, "\(HookLine.installed) (roga-hooks plugin).\(last)")
        case .needsTrust?:
            (tone, text) = (.warn, "Installed, but Codex hasn't trusted it yet. Open /hooks in Codex to trust it.")
        case .disabled?:
            (tone, text) = (.warn, "Installed, but disabled in \(kind.name).")
        case .anotherCopy(let folder)?:
            (tone, text) = (.warn, "Installed by another copy of Roga, from \(abbreviated(folder)).")
        case .unknown(let words)?:
            (tone, text) = (.warn, "Couldn't check whether it's installed: \(sentence(words))")
        }

        let action = agents.hookStatus[kind].map { AgentProvider.offeredAction($0, for: kind) }
        var button = action.map { HookLine.Offer(action: $0, title: $0 == .install ? "Install…" : "Remove…", isEnabled: true) }
        var note: String?
        switch agents.hookWork[kind] {
        case .installing?:
            button = HookLine.Offer(action: .install, title: "Installing…", isEnabled: false, isWorking: true)
        case .removing?:
            button = HookLine.Offer(action: .remove, title: "Removing…", isEnabled: false, isWorking: true)
        case .failed?, nil:
            if button?.action == .install, agents.helperPath == nil {
                button?.isEnabled = false
                note = "Hook installation unavailable: roga helper missing."
            }
        }
        return HookLine(tone: tone, text: text, button: button, note: note, problems: (failure.map { [$0] } ?? []) + filesError)
    }

    /// "Last heard from 2 minutes ago, in acme/api.", or nil when Roga hasn't
    /// heard from the agent since it opened.
    static func heardSentence(_ heard: AgentProvider.Heard?, now: Date, place: (String) -> String) -> String? {
        guard let heard else { return nil }
        let folder = heard.cwd.map { ", " + place($0) } ?? ""
        return "Last heard from \(ago(heard.date, now: now))\(folder)."
    }

    /// Where an agent was working, as the sidebar knows it: the repository
    /// with its owner, as in "in acme/api", with the branch for a linked
    /// worktree, and otherwise the folder's name. `selection` is the listed
    /// worktree the folder is in, which `HeardPlaces` finds.
    static func place(of folder: String, at selection: WorktreeSelection?, in list: RepositoryList) -> String {
        guard let selection, let repository = list.repository(at: selection.repository) else {
            return "in " + (folder as NSString).lastPathComponent
        }
        if let worktree = repository.worktrees.first(where: { $0.path == selection.worktree }), !worktree.isMain {
            return "on \(worktree.title) in \(repository.nameWithOwner)"
        }
        return "in " + repository.nameWithOwner
    }

    /// How long ago, in words: "less than a minute ago", "2 minutes ago",
    /// "1 hour ago", "yesterday", "3 days ago".
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "less than a minute ago" }
        if minutes < 60 { return count(minutes, "minute") + " ago" }
        let hours = minutes / 60
        if hours < 24 { return count(hours, "hour") + " ago" }
        let days = hours / 24
        return days == 1 ? "yesterday" : "\(days) days ago"
    }

    /// Why the sidebar can't show marks, or nil when it can.
    ///
    /// When the socket couldn't be opened, the listener's own words say so
    /// and where, as in "Can't listen for agents' hooks at …, because
    /// bind failed: Address already in use.", so the notice starts with them
    /// rather than saying it twice.
    static func listeningNotice(_ listening: AgentMonitor.Listening) -> String? {
        switch listening {
        case .starting, .listening:
            return nil
        case .anotherCopy:
            return "Another copy of Roga is listening for the agents' hooks, so this one can't show their marks in the sidebar. Quit the other copy, then try again."
        case .failed(let words):
            let reason = sentence(abbreviatingPaths(in: words))
            let lead = reason.hasPrefix("Can't listen") ? "" : "Can't listen for the agents' hooks. "
            return "\(lead)\(reason) Until then, the sidebar can't show the agents' marks."
        }
    }

    /// A path with the home folder as `~`.
    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Words with the home folder as `~` in the paths they mention, as
    /// Settings writes paths everywhere else.
    static func abbreviatingPaths(in words: String) -> String {
        words.replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/")
    }

    /// Words as a sentence: trimmed, with a period unless they end in one.
    static func sentence(_ words: String) -> String {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?…".contains(last) ? trimmed : trimmed + "."
    }

    private static func count(_ number: Int, _ unit: String) -> String {
        number == 1 ? "1 \(unit)" : "\(number) \(unit)s"
    }
}

/// Where the hooks' rows say an agent was last heard from, as the sidebar
/// names the folder (`AgentSummaries.place`). Each page that says it keeps
/// one.
///
/// Those rows redraw for every event an agent sends, which is each tool it
/// runs, and finding a folder's worktree as `RepositoryList.worktree(containing:)`
/// does resolves every worktree's folder on the file system, on the main
/// actor: with a few hundred worktrees, over 10 ms each time, and forever on
/// a stalled volume. So this resolves each folder once, away from the main
/// actor, as the agents' monitor does for the marks, and a redraw only
/// compares what's resolved. Until a folder is, it compares as it's spelled,
/// which for nearly every folder is the same, and the rows say the place
/// again once it changes where the folder goes.
@Observable
final class HeardPlaces {
    /// Folders as they compare, with symbolic links resolved, by how git and
    /// the agents spell them.
    @ObservationIgnored private var resolved: [String: String] = [:]
    @ObservationIgnored private var resolving: Set<String> = []
    /// Goes up when a folder resolves to something other than its spelling,
    /// so that the rows that read a place read it again.
    private var version = 0
    /// How a folder becomes comparable, away from the main actor, which
    /// tests count.
    @ObservationIgnored private let resolve: @Sendable (String) -> String

    init(resolve: @escaping @Sendable (String) -> String = RepositoryList.comparablePath) {
        self.resolve = resolve
    }

    /// Where a folder is, as in "in acme/api" or "on agent/fix-login in
    /// acme/api", or the folder's own name when it's not in the sidebar.
    func place(of folder: String, in list: RepositoryList) -> String {
        _ = version
        var unresolved: [String] = []
        func comparable(_ folder: String) -> String {
            if let known = resolved[folder] { return known }
            unresolved.append(folder)
            return RepositoryList.standardizedPath(folder)
        }
        let places = list.repositories.flatMap { repository in
            repository.worktrees.filter { !$0.isBare && !$0.isPrunable }.map { worktree in
                (folder: comparable(worktree.path), value: WorktreeSelection(repository: repository.path, worktree: worktree.path))
            }
        }
        let selection = RepositoryList.deepest(holding: comparable(folder), in: places)
        resolveLater(unresolved)
        return AgentSummaries.place(of: folder, at: selection, in: list)
    }

    /// Resolves folders together, away from the main actor, unless they're
    /// being resolved already.
    private func resolveLater(_ folders: [String]) {
        let folders = folders.filter { resolving.insert($0).inserted }
        guard !folders.isEmpty else { return }
        let resolve = resolve
        Task { [weak self] in
            let results = await Self.resolve(folders, with: resolve)
            self?.finishResolving(results)
        }
    }

    @concurrent
    private static func resolve(_ folders: [String], with resolve: @Sendable (String) -> String) async -> [(folder: String, resolved: String)] {
        folders.map { ($0, resolve($0)) }
    }

    private func finishResolving(_ results: [(folder: String, resolved: String)]) {
        var moved = false
        for (folder, comparable) in results {
            resolving.remove(folder)
            resolved[folder] = comparable
            if comparable != RepositoryList.standardizedPath(folder) { moved = true }
        }
        if moved { version &+= 1 }
    }

    /// Whether a folder it was asked about is still being resolved, for
    /// tests.
    var isResolving: Bool { !resolving.isEmpty }
}
