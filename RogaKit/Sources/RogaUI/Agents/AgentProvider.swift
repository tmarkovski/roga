import AgentEngine
import AgentHooks
import Foundation
import GitRunner
import Observation

/// Finds the agents' command-line tools, installs Roga's hooks in them, and
/// says how to run them to write a commit message (decision 41).
///
/// There's one for the whole app, like `GitProvider`, because the agents
/// belong to the Mac rather than to a repository. It starts once git is
/// ready, since it runs the agents with the same environment and the same
/// login shell's `PATH` as git, and it follows what people choose in
/// Settings through UserDefaults.
@MainActor @Observable
public final class AgentProvider {
    /// What the hooks' button offers for an agent, and what a failure was
    /// trying to do.
    enum HookAction: Hashable {
        case install
        case remove
    }

    /// What Install or Remove is doing for an agent, while it does it, or how
    /// it failed.
    enum HookWork: Equatable {
        case installing
        case removing
        /// What failed, and how, in the agent's own words.
        case failed(HookAction, String)

        /// How it failed, in the agent's own words, when it did.
        var failure: String? {
            if case .failed(_, let words) = self { words } else { nil }
        }
    }

    /// When an agent's hooks last reached Roga, and from which folder.
    struct Heard: Equatable {
        var date: Date
        var cwd: String?
    }

    /// Roga's folder in Application Support, where the plugin, the launcher
    /// and the hooks' socket live.
    let supportFolder: URL
    /// The `roga` helper inside the running app, which the launcher runs, or
    /// nil when this build has none.
    let helperPath: String?

    /// The programs that run the agents, once git is ready.
    private(set) var programs: Programs?
    /// What installs and checks Roga's hooks, once git is ready.
    private(set) var installer: HookInstaller?
    /// What looking for each agent came to. An agent is absent while Roga is
    /// still looking for it.
    private(set) var lookups: [AgentKind: AgentLookup] = [:]
    /// Every copy of each agent that Roga found, which setup and Settings
    /// list. An agent is absent until Roga has looked for it once, and what
    /// it found stays while it looks again.
    private(set) var surveys: [AgentKind: AgentSurvey] = [:]
    /// What's chosen for each agent, kept current as UserDefaults changes.
    private(set) var settings: [AgentKind: AgentSettings]
    /// The model Codex uses by default, from the top of its `config.toml`,
    /// which pickers show as "Default · <model>". Roga only reads that file.
    private(set) var codexDefaultModel: String?
    /// The MCP servers in Codex's `config.toml`, which Generate turns off,
    /// as Roga last read them.
    private(set) var codexMCPServers: [String] = []
    /// Whether each found agent runs Roga's hooks. An agent is absent while
    /// Roga checks, and while it isn't found.
    private(set) var hookStatus: [AgentKind: HookStatus] = [:]
    /// Install or Remove under way for an agent, or how it last failed.
    ///
    /// A failure belongs to the app rather than to the dialog or the Settings
    /// sheet that ran the commands, so every window's Settings shows it under
    /// the agent's hooks for as long as it applies. It goes once the agent's
    /// status no longer offers the action that failed, as when someone put it
    /// right in Terminal: a failed install once the hooks read installed, and
    /// a failed remove once they read not installed. It goes too when Look
    /// Again starts afresh. The status read right after the failure never
    /// sends it away, so that it can be read whatever that status says.
    private(set) var hookWork: [AgentKind: HookWork] = [:]
    /// Why the plugin's files couldn't be written when this copy of Roga
    /// took the hooks' socket, if they couldn't, which leaves Install with
    /// nothing to install.
    private(set) var pluginFilesError: String?
    /// Whether this copy of Roga holds the hooks' socket, which makes it the
    /// copy that writes the launcher.
    @ObservationIgnored private var pointsTheHooksHere = false
    /// The agent chosen for Generate, as stored, whether or not it's usable.
    private var chosenGenerateAgent: AgentKind?

    @ObservationIgnored private let defaults: UserDefaults
    /// Codex's folder, for tests, or nil for `CODEX_HOME` or `~/.codex`.
    @ObservationIgnored private let codexHome: String?
    /// Where to look after `PATH`, for tests, or nil for each agent's own
    /// well-known places.
    @ObservationIgnored private let wellKnown: [AgentKind: [String]]?
    @ObservationIgnored private var git: Git?
    /// Which look and which status check is the latest for each agent, so an
    /// older one that finishes later doesn't replace what it found.
    @ObservationIgnored private var lookGeneration: [AgentKind: Int] = [:]
    @ObservationIgnored private var statusGeneration: [AgentKind: Int] = [:]
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?
    /// Which programs `showsPath` said need their path, since views ask as
    /// they draw. A look starts it again.
    @ObservationIgnored private var pathIsShown: [String: Bool] = [:]

    /// - Parameters:
    ///   - supportFolder: Roga's folder in Application Support, which is
    ///     `standardSupportFolder` in the app.
    ///   - helperPath: The helper inside the app, `bundledHelperPath`, or nil
    ///     when there's none, in which case Roga doesn't write the plugin.
    public convenience init(supportFolder: URL, helperPath: String?, defaults: UserDefaults = .standard) {
        self.init(supportFolder: supportFolder, helperPath: helperPath, defaults: defaults, codexHome: nil, wellKnown: nil)
    }

    /// The same, with Codex's folder and the places to look after `PATH`
    /// chosen, so tests never find or touch the real agents.
    init(supportFolder: URL, helperPath: String?, defaults: UserDefaults, codexHome: String?, wellKnown: [AgentKind: [String]]?) {
        self.supportFolder = supportFolder
        self.helperPath = helperPath
        self.defaults = defaults
        self.codexHome = codexHome
        self.wellKnown = wellKnown
        settings = Self.readSettings(from: defaults)
        chosenGenerateAgent = defaults.string(forKey: AgentPreferences.generateAgentKey).flatMap(AgentKind.init(rawValue:))
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadSettings()
            }
        }
    }

    isolated deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    /// Roga's folder in Application Support, named after this copy's bundle
    /// ID the way `HookSocket` names it, so that a copy for trying things out
    /// hears only from its own hooks.
    public static var standardSupportFolder: URL {
        HookSocket.supportFolder(bundleIdentifier: Bundle.main.bundleIdentifier ?? HookSocket.defaultBundleIdentifier)
    }

    /// The helper inside the running app, or nil when this build doesn't have
    /// one, such as a development build from before the helper's target.
    public static var bundledHelperPath: String? {
        let path = Bundle.main.bundleURL.appending(path: "Contents/Helpers/roga").path(percentEncoded: false)
        return ExecutableSearch.isExecutableFile(path) ? path : nil
    }

    // MARK: Starting and looking

    /// Starts once git is ready: writes the plugin's files and the launcher
    /// if this copy of Roga hears the hooks and there's a helper to point the
    /// launcher at, finds both agents, then asks each one found whether it
    /// runs Roga's hooks. Calling it again does nothing.
    func start(git: Git) {
        guard self.git == nil else { return }
        self.git = git
        let programs = Programs(sharingWith: git)
        self.programs = programs
        let installer = HookInstaller(programs: programs, supportFolder: supportFolder, codexHome: codexHome)
        self.installer = installer
        let writesFiles = pointsTheHooksHere
        let helperPath = helperPath
        Task {
            if writesFiles, let helperPath {
                pluginFilesError = await Self.writeFiles(installer, helperPath: helperPath)
            }
            look(for: AgentKind.allCases)
        }
    }

    /// Points the launcher, and so the hooks, at this copy's helper, because
    /// this copy of Roga holds the hooks' socket. The agent monitor calls it
    /// each time it takes the socket: at launch, or when Try Again takes it
    /// over from a copy that has quit.
    ///
    /// Every copy with the same bundle ID shares the support folder and its
    /// launcher, as a build from Xcode does with the copy in Applications,
    /// or a copy opened from a disk image. If each wrote the launcher as it
    /// started, a copy that couldn't take the socket would point the hooks at
    /// its own helper, and once that copy went away, the launcher would run
    /// nothing, and the copy that listens would hear nothing more.
    func pointTheHooksHere() {
        pointsTheHooksHere = true
        // Before git is ready, `start` writes them.
        guard let installer, let helperPath else { return }
        Task {
            pluginFilesError = await Self.writeFiles(installer, helperPath: helperPath)
        }
    }

    /// Whether Roga is still looking for either agent, which it is too before
    /// git is ready.
    var isLooking: Bool {
        AgentKind.allCases.contains { lookups[$0] == nil }
    }

    /// Looks for both agents again, and then checks their hooks again, as
    /// Look Again in Settings does after someone installs or updates one.
    /// It starts afresh, so how Install or Remove last failed goes too.
    func lookAgain() {
        for (kind, work) in hookWork where work.failure != nil {
            hookWork[kind] = nil
        }
        look(for: AgentKind.allCases)
    }

    /// The copy of an agent that Roga runs, once it has found one it can use.
    func installation(_ kind: AgentKind) -> AgentInstallation? {
        if case .found(let installation)? = lookups[kind] { installation } else { nil }
    }

    private func look(for kinds: [AgentKind]) {
        guard let git, let programs else { return }
        for kind in kinds {
            let generation = (lookGeneration[kind] ?? 0) + 1
            lookGeneration[kind] = generation
            statusGeneration[kind, default: 0] += 1
            lookups[kind] = nil
            hookStatus[kind] = nil
            // Someone may have installed or moved a program since.
            pathIsShown = [:]
            let program = settings[kind]?.program
            let searchPath = git.installation.searchPath
            let wellKnown = wellKnown.map { $0[kind] ?? [] }
            let codexConfiguration = kind == .codex ? installer.map(Self.codexConfigurationFile) : nil
            Task {
                // Every copy is asked for its version, so that the menus can
                // list them, and the one Roga runs comes out of that list
                // unless someone chose a program that isn't on it.
                let survey = await AgentInstallation.survey(kind, searchPath: searchPath, programs: programs, wellKnown: wellKnown)
                var lookup = Self.lookup(kind, program: program, in: survey)
                if lookup == nil {
                    lookup = await AgentInstallation.locate(kind, configuredPath: program, searchPath: searchPath, programs: programs, wellKnown: wellKnown)
                }
                var text: String?
                if let codexConfiguration { text = await Self.read(codexConfiguration) }
                guard lookGeneration[kind] == generation else { return }
                surveys[kind] = survey
                lookups[kind] = lookup
                if kind == .codex {
                    codexDefaultModel = text.flatMap(Self.codexDefaultModel(inConfiguration:))
                    let servers = text.map(CodexConfiguration.mcpServers(in:)) ?? []
                    if servers != codexMCPServers { codexMCPServers = servers }
                }
                refreshHookStatus(kind)
            }
        }
    }

    // MARK: What's chosen

    /// The agents Roga can run, found and turned on, in `AgentKind.allCases`
    /// order.
    var usableAgents: [AgentKind] {
        AgentKind.allCases.filter { installation($0) != nil && settings[$0]?.isEnabled != false }
    }

    /// The agent Generate runs: the one chosen when it's usable, and
    /// otherwise the first usable one.
    var generateAgent: AgentKind? {
        let usable = usableAgents
        if let chosenGenerateAgent, usable.contains(chosenGenerateAgent) { return chosenGenerateAgent }
        return usable.first
    }

    /// Makes `kind` the agent Generate runs, from now on.
    func setGenerateAgent(_ kind: AgentKind) {
        defaults.set(kind.rawValue, forKey: AgentPreferences.generateAgentKey)
        chosenGenerateAgent = kind
    }

    /// How to run an agent that Roga found, with what's chosen for it, whether
    /// or not it's turned on, so that Settings can show its command.
    func commitMessageAgent(_ kind: AgentKind) -> CommitMessageAgent? {
        guard let installation = installation(kind) else { return nil }
        let settings = settings[kind] ?? AgentSettings.read(kind, from: defaults)
        return CommitMessageAgent(
            kind: kind,
            executable: installation.executable,
            model: settings.model.isEmpty ? nil : settings.model,
            effort: settings.effort.isEmpty ? nil : settings.effort,
            extraArguments: settings.extraArguments,
            timeLimit: settings.timeLimit,
            mcpServers: kind == .codex ? codexMCPServers : [],
            codexConfigurationFile: kind == .codex ? installer.map(Self.codexConfigurationFile) : nil
        )
    }

    /// Everything a run of Generate needs, with `kind` or the agent Generate
    /// runs, or nil when that agent can't be used.
    func generation(with kind: AgentKind? = nil) -> GenerationSetup? {
        guard let kind = kind ?? generateAgent, usableAgents.contains(kind),
              let agent = commitMessageAgent(kind), let programs
        else { return nil }
        return GenerationSetup(
            kind: kind,
            agent: agent,
            programs: programs,
            style: AgentPreferences.instructions(in: defaults),
            matchesStyle: AgentPreferences.matchesStyle(in: defaults),
            label: GenerationSetup.label(kind, model: agent.model ?? ""),
            showsPath: showsPath(agent.executable)
        )
    }

    /// Whether a command block has to show a program by its path, because its
    /// name alone, typed in a terminal, would run another copy or nothing, as
    /// for the Codex inside the ChatGPT app.
    func showsPath(_ executable: String) -> Bool {
        if let known = pathIsShown[executable] { return known }
        guard let git else { return true }
        let name = (executable as NSString).lastPathComponent
        let first = ExecutableSearch.candidates(named: [name], searchPath: git.installation.searchPath, wellKnown: []).first
        let shows = first.map(ExecutableSearch.realPath) != ExecutableSearch.realPath(executable)
        pathIsShown[executable] = shows
        return shows
    }

    /// Reads what's chosen again. A program that changed means looking for
    /// that agent again, so Settings doesn't have to ask.
    func reloadSettings() {
        let chosen = defaults.string(forKey: AgentPreferences.generateAgentKey).flatMap(AgentKind.init(rawValue:))
        if chosen != chosenGenerateAgent { chosenGenerateAgent = chosen }
        let read = Self.readSettings(from: defaults)
        guard read != settings else { return }
        let changedPrograms = AgentKind.allCases.filter { read[$0]?.program != settings[$0]?.program }
        settings = read
        for kind in changedPrograms {
            // A copy Roga already asked for its version needs no new look,
            // so choosing one from a menu shows at once.
            if let survey = surveys[kind], let lookup = Self.lookup(kind, program: read[kind]?.program, in: survey) {
                lookGeneration[kind, default: 0] += 1
                pathIsShown = [:]
                lookups[kind] = lookup
                refreshHookStatus(kind)
            } else {
                look(for: [kind])
            }
        }
    }

    /// What looking for an agent comes to, from the copies Roga already
    /// asked: the one Roga would pick when nobody chose a program, and the
    /// chosen one when it's among them. It's nil for a chosen program that
    /// isn't, which has to be asked for its version.
    nonisolated static func lookup(_ kind: AgentKind, program: String?, in survey: AgentSurvey) -> AgentLookup? {
        guard let program else { return survey.lookup }
        guard let copy = survey.copies.first(where: { $0.executable == program }) else { return nil }
        if let skipped = copy.skipped { return .configuredUnusable(skipped) }
        guard let version = copy.version else { return nil }
        return .found(AgentInstallation(kind: kind, executable: program, version: version))
    }

    private static func readSettings(from defaults: UserDefaults) -> [AgentKind: AgentSettings] {
        Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, AgentSettings.read($0, from: defaults)) })
    }

    // MARK: Hooks

    /// The exact commands Install runs for an agent (decision 29), or nil
    /// while Roga hasn't found it.
    func installCommands(_ kind: AgentKind) -> [ProgramCommand]? {
        guard let installer, let installation = installation(kind) else { return nil }
        return installer.installCommands(kind, executable: installation.executable)
    }

    /// The exact commands Remove runs for an agent, or nil while Roga hasn't
    /// found it.
    func removeCommands(_ kind: AgentKind) -> [ProgramCommand]? {
        guard let installer, let installation = installation(kind) else { return nil }
        return installer.removeCommands(kind, executable: installation.executable)
    }

    /// Installs Roga's hooks in each agent in turn, going on to the next when
    /// one fails, and then checks each one's hooks again.
    ///
    /// - Returns: Whether every install worked. One that didn't leaves
    ///   `hookWork` failed, in the agent's own words.
    @discardableResult
    func installHooks(_ kinds: [AgentKind]) async -> Bool {
        await work(.install, on: kinds) { installer, kind, executable in
            try await installer.install(kind, executable: executable)
        }
    }

    /// Removes Roga's hooks from an agent, and then checks its hooks again.
    @discardableResult
    func removeHooks(_ kind: AgentKind) async -> Bool {
        await work(.remove, on: [kind]) { installer, kind, executable in
            try await installer.remove(kind, executable: executable)
        }
    }

    private func work(
        _ action: HookAction,
        on kinds: [AgentKind],
        _ run: @Sendable (HookInstaller, AgentKind, String) async throws -> Void
    ) async -> Bool {
        guard let installer else { return false }
        var succeeded = true
        for kind in kinds {
            guard let executable = installation(kind)?.executable else {
                hookWork[kind] = .failed(action, "Roga hasn't found \(kind.name).")
                succeeded = false
                continue
            }
            hookWork[kind] = action == .install ? .installing : .removing
            do {
                try await run(installer, kind, executable)
                hookWork[kind] = nil
            } catch let error as HookInstallError {
                hookWork[kind] = .failed(action, error.message)
                succeeded = false
            } catch {
                hookWork[kind] = .failed(action, action == .remove ? "Roga stopped removing its hooks." : "Roga stopped installing its hooks.")
                succeeded = false
            }
        }
        // A part of the commands may have worked, so the status that comes
        // next can read installed after an install failed. The failure stays
        // all the same, until a later status shows it no longer applies.
        for kind in kinds { refreshHookStatus(kind, keepingFailure: true) }
        return succeeded
    }

    /// Asks each found agent again whether it runs Roga's hooks.
    func refreshHookStatus() {
        for kind in AgentKind.allCases { refreshHookStatus(kind) }
    }

    /// - Parameter keepingFailure: Whether the status read keeps how Install
    ///   or Remove failed even if it no longer offers that action, as it does
    ///   right after the failure.
    private func refreshHookStatus(_ kind: AgentKind, keepingFailure: Bool = false) {
        statusGeneration[kind, default: 0] += 1
        let generation = statusGeneration[kind] ?? 0
        guard let installer, let installation = installation(kind) else {
            hookStatus[kind] = nil
            return
        }
        hookStatus[kind] = nil
        Task {
            let status = await installer.status(kind, executable: installation.executable)
            guard statusGeneration[kind] == generation else { return }
            hookStatus[kind] = status
            if !keepingFailure, case .failed(let action, _)? = hookWork[kind], Self.offeredAction(status, for: kind) != action {
                hookWork[kind] = nil
            }
        }
    }

    /// What the hooks' button offers in an agent with this status: Install
    /// where this copy's hooks aren't there, and Remove where they are, even
    /// if they don't run. Claude Code takes over another copy's hooks when it
    /// installs this one's, while Codex refuses until they're removed.
    static func offeredAction(_ status: HookStatus, for kind: AgentKind) -> HookAction {
        switch status {
        case .notInstalled, .unknown: .install
        case .installed, .needsTrust, .disabled: .remove
        case .anotherCopy: kind == .claude ? .install : .remove
        }
    }

    // MARK: Files

    /// Writes the plugin and the launcher, away from the main actor, and says
    /// why it couldn't.
    @concurrent
    private static func writeFiles(_ installer: HookInstaller, helperPath: String) async -> String? {
        do {
            try installer.writeFiles(helperPath: helperPath)
            return nil
        } catch {
            return "Roga couldn't write its hooks' files in \(installer.pluginsFolder.path(percentEncoded: false)): \(error.localizedDescription)"
        }
    }

    /// Codex's `config.toml`, in the folder the installer uses for Codex.
    private static func codexConfigurationFile(_ installer: HookInstaller) -> String {
        installer.codexHome + "/config.toml"
    }

    /// A small text file's contents, read away from the main actor, or nil
    /// when it can't be read.
    @concurrent
    private static func read(_ path: String) async -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// The model in a Codex `config.toml`: its top-level `model = "…"`, before
    /// the first table. Roga doesn't parse TOML any further than that.

    nonisolated static func codexDefaultModel(inConfiguration text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }
            guard trimmed.hasPrefix("model"), let equals = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
            guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else { return nil }
            let model = String(value.dropFirst().dropLast())
            return model.isEmpty ? nil : model
        }
        return nil
    }

    // MARK: Tests

    /// Puts the provider in a state, for tests of what views show in it,
    /// without finding or running anything.
    func setStateForTests(
        lookups: [AgentKind: AgentLookup]? = nil,
        surveys: [AgentKind: AgentSurvey]? = nil,
        hookStatus: [AgentKind: HookStatus]? = nil,
        hookWork: [AgentKind: HookWork]? = nil,
        codexDefaultModel: String?? = nil,
        programs: Programs?? = nil
    ) {
        if let lookups { self.lookups = lookups }
        if let surveys { self.surveys = surveys }
        if let hookStatus { self.hookStatus = hookStatus }
        if let hookWork { self.hookWork = hookWork }
        if let codexDefaultModel { self.codexDefaultModel = codexDefaultModel }
        if let programs { self.programs = programs }
    }
}

/// Everything one run of Generate needs (decision 41).
struct GenerationSetup: Sendable {
    var kind: AgentKind
    var agent: CommitMessageAgent
    var programs: Programs
    /// The instructions for the message's style, which are Roga's own unless
    /// someone edited them.
    var style: String
    /// Whether to send the repository's recent subjects.
    var matchesStyle: Bool
    /// The agent and its model, as in "Claude Code · haiku", or the agent's
    /// name alone when the model is its own default.
    var label: String
    /// Whether command blocks show the program by its path, because its name
    /// wouldn't find it.
    var showsPath = false

    /// The command, as a command block shows it: a line that says where the
    /// staged changes go, since the command reads them from standard input,
    /// and then the command.
    func terminal(worktree: String, hasDraft: Bool) -> [TerminalLine] {
        [.comment("The staged changes go to its standard input"), .program(command(worktree: worktree, hasDraft: hasDraft), showsPath: showsPath)]
    }

    /// The exact command the run starts, for the popover and the Commit page
    /// to show (decision 29).
    func command(worktree: String, hasDraft: Bool) -> ProgramCommand {
        CommitMessageCommand.command(for: agent, worktree: worktree, style: style, hasDraft: hasDraft)
    }

    static func label(_ kind: AgentKind, model: String) -> String {
        model.isEmpty ? kind.name : "\(kind.name) · \(model)"
    }
}
