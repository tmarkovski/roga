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
    /// What Install or Remove is doing for an agent, while it does it, or how
    /// it failed, in the agent's own words.
    enum HookWork: Equatable {
        case installing
        case removing
        case failed(String)
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
    /// What's chosen for each agent, kept current as UserDefaults changes.
    private(set) var settings: [AgentKind: AgentSettings]
    /// The model Codex uses by default, from the top of its `config.toml`,
    /// which pickers show as "Default · <model>". Roga only reads that file.
    private(set) var codexDefaultModel: String?
    /// Whether each found agent runs Roga's hooks. An agent is absent while
    /// Roga checks, and while it isn't found.
    private(set) var hookStatus: [AgentKind: HookStatus] = [:]
    /// Install or Remove under way for an agent, or how it last failed.
    private(set) var hookWork: [AgentKind: HookWork] = [:]
    /// Why the plugin's files couldn't be written at launch, when they
    /// couldn't, which leaves Install with nothing to install.
    private(set) var pluginFilesError: String?
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
    /// when there's a helper to point it at, finds both agents, then asks each
    /// one found whether it runs Roga's hooks. Calling it again does nothing.
    func start(git: Git) {
        guard self.git == nil else { return }
        self.git = git
        let programs = Programs(sharingWith: git)
        self.programs = programs
        let installer = HookInstaller(programs: programs, supportFolder: supportFolder, codexHome: codexHome)
        self.installer = installer
        let helperPath = helperPath
        Task {
            if let helperPath {
                pluginFilesError = await Self.writeFiles(installer, helperPath: helperPath)
            }
            look(for: AgentKind.allCases)
        }
    }

    /// Whether Roga is still looking for either agent, which it is too before
    /// git is ready.
    var isLooking: Bool {
        AgentKind.allCases.contains { lookups[$0] == nil }
    }

    /// Looks for both agents again, and then checks their hooks again, as
    /// Look Again in Settings does after someone installs or updates one.
    func lookAgain() {
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
            let codexConfiguration = kind == .codex ? installer.map { $0.codexHome + "/config.toml" } : nil
            Task {
                let lookup = await AgentInstallation.locate(kind, configuredPath: program, searchPath: searchPath, programs: programs, wellKnown: wellKnown)
                var model: String?
                if let codexConfiguration { model = await Self.codexDefaultModel(inFile: codexConfiguration) }
                guard lookGeneration[kind] == generation else { return }
                lookups[kind] = lookup
                if kind == .codex { codexDefaultModel = model }
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
            timeLimit: settings.timeLimit
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
        look(for: changedPrograms)
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
        await work(.installing, on: kinds) { installer, kind, executable in
            try await installer.install(kind, executable: executable)
        }
    }

    /// Removes Roga's hooks from an agent, and then checks its hooks again.
    @discardableResult
    func removeHooks(_ kind: AgentKind) async -> Bool {
        await work(.removing, on: [kind]) { installer, kind, executable in
            try await installer.remove(kind, executable: executable)
        }
    }

    private func work(
        _ work: HookWork,
        on kinds: [AgentKind],
        _ run: @Sendable (HookInstaller, AgentKind, String) async throws -> Void
    ) async -> Bool {
        guard let installer else { return false }
        var succeeded = true
        for kind in kinds {
            guard let executable = installation(kind)?.executable else {
                hookWork[kind] = .failed("Roga hasn't found \(kind.name).")
                succeeded = false
                continue
            }
            hookWork[kind] = work
            do {
                try await run(installer, kind, executable)
                hookWork[kind] = nil
            } catch let error as HookInstallError {
                hookWork[kind] = .failed(error.message)
                succeeded = false
            } catch {
                hookWork[kind] = .failed(work == .removing ? "Roga stopped removing its hooks." : "Roga stopped installing its hooks.")
                succeeded = false
            }
        }
        for kind in kinds { refreshHookStatus(kind) }
        return succeeded
    }

    /// Asks each found agent again whether it runs Roga's hooks.
    func refreshHookStatus() {
        for kind in AgentKind.allCases { refreshHookStatus(kind) }
    }

    private func refreshHookStatus(_ kind: AgentKind) {
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

    /// The model in a Codex `config.toml`: its top-level `model = "…"`, before
    /// the first table. Roga doesn't parse TOML any further than that.
    @concurrent
    static func codexDefaultModel(inFile path: String) async -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return codexDefaultModel(inConfiguration: text)
    }

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
        hookStatus: [AgentKind: HookStatus]? = nil,
        hookWork: [AgentKind: HookWork]? = nil,
        codexDefaultModel: String?? = nil,
        programs: Programs?? = nil
    ) {
        if let lookups { self.lookups = lookups }
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
