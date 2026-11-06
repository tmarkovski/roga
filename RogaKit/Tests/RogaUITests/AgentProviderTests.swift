import AgentEngine
import Foundation
import GitRunner
import Testing
@testable import RogaUI

/// Finding the agents, writing the plugin, and what Generate would run, with
/// fake `claude` and `codex` programs in a `PATH` of their own, a temporary
/// support folder and Codex folder, and defaults of the test's own.
@Suite(.timeLimit(.minutes(1)))
struct AgentProviderTests {
    let bin: String
    let support: String
    let codexHome: String
    let log: String
    let defaults: UserDefaults
    let defaultsName: String

    init() throws {
        let folder = try AgentTestSupport.folder()
        bin = folder + "/bin"
        support = folder + "/support"
        codexHome = folder + "/codex"
        log = folder + "/runs.log"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        (defaults, defaultsName) = AgentTestSupport.defaults()
    }

    private func clean() {
        AgentTestSupport.remove(defaults, named: defaultsName)
    }

    /// A provider with both fake agents, started and done looking.
    private func started(helperPath: String? = nil, claudeBody: String = "") async throws -> AgentProvider {
        try AgentTestSupport.claude(in: bin, log: log, body: claudeBody)
        try AgentTestSupport.codex(in: bin, log: log)
        let provider = AgentTestSupport.provider(support: support, helperPath: helperPath, defaults: defaults, codexHome: codexHome)
        provider.start(git: try await AgentTestSupport.git(searchPath: bin))
        #expect(await AgentTestSupport.eventually { !provider.isLooking && provider.hookStatus.count == 2 })
        return provider
    }

    @Test func findsBothAgentsInThePath() async throws {
        defer { clean() }
        let provider = try await started()
        #expect(provider.installation(.claude)?.executable == bin + "/claude")
        #expect(provider.installation(.claude)?.version == AgentVersion(major: 2, minor: 1, patch: 290))
        #expect(provider.installation(.codex)?.executable == bin + "/codex")
        #expect(provider.usableAgents == [.claude, .codex])
        #expect(provider.generateAgent == .claude)
        #expect(provider.hookStatus == [.claude: .notInstalled, .codex: .notInstalled])
        #expect(provider.programs != nil)
        // Both were asked about their plugins, Codex in its own folder.
        let asked = AgentTestSupport.runs(in: log)
        #expect(asked.filter { $0 == ["plugin", "list", "--json"] }.count == 2)
    }

    @Test func anAgentThatIsntThereIsNotFound() async throws {
        defer { clean() }
        try AgentTestSupport.claude(in: bin, log: log)
        let provider = AgentTestSupport.provider(support: support, defaults: defaults, codexHome: codexHome)
        #expect(provider.isLooking)
        provider.start(git: try await AgentTestSupport.git(searchPath: bin))
        #expect(await AgentTestSupport.eventually { !provider.isLooking })
        #expect(provider.lookups[.codex] == .notFound)
        #expect(provider.installation(.codex) == nil)
        #expect(provider.installCommands(.codex) == nil)
        #expect(provider.usableAgents == [.claude])
        #expect(await AgentTestSupport.eventually { provider.hookStatus[.claude] != nil })
        #expect(provider.hookStatus[.codex] == nil)
    }

    @Test func writesThePluginOnlyWhenThereIsAHelper() async throws {
        defer { clean() }
        let helper = try AgentTestSupport.script("exit 0", named: "roga", in: bin)
        _ = try await started(helperPath: helper)
        let manager = FileManager.default
        #expect(manager.fileExists(atPath: support + "/plugins/.claude-plugin/marketplace.json"))
        #expect(manager.fileExists(atPath: support + "/plugins/roga-hooks/hooks/hooks.json"))
        #expect(manager.fileExists(atPath: support + "/plugins/roga-hooks/hooks/codex.json"))
        let launcher = try String(contentsOfFile: support + "/bin/roga-hook", encoding: .utf8)
        #expect(launcher.contains(helper))
        #expect(manager.isExecutableFile(atPath: support + "/bin/roga-hook"))
    }

    @Test func writesNothingWithoutAHelper() async throws {
        defer { clean() }
        let provider = try await started()
        #expect(provider.helperPath == nil)
        #expect(!FileManager.default.fileExists(atPath: support + "/plugins"))
        #expect(!FileManager.default.fileExists(atPath: support + "/bin"))
        #expect(provider.pluginFilesError == nil)
    }

    @Test func usableAgentsFollowTheSwitch() async throws {
        defer { clean() }
        let provider = try await started()
        provider.setGenerateAgent(.claude)
        defaults.set(false, forKey: AgentPreferences.enabledKey(.claude))
        provider.reloadSettings()
        #expect(provider.settings[.claude]?.isEnabled == false)
        #expect(provider.usableAgents == [.codex])
        // The choice is kept for when Claude Code is turned on again.
        #expect(provider.generateAgent == .codex)
        #expect(provider.generation()?.kind == .codex)
        #expect(provider.generation(with: .claude) == nil)
        // Settings still shows how it would run.
        #expect(provider.commitMessageAgent(.claude) != nil)

        defaults.set(true, forKey: AgentPreferences.enabledKey(.claude))
        provider.reloadSettings()
        #expect(provider.generateAgent == .claude)
        #expect(defaults.string(forKey: AgentPreferences.generateAgentKey) == "claude")
    }

    @Test func followsChangesToTheDefaultsByItself() async throws {
        defer { clean() }
        let provider = try await started()
        defaults.set(false, forKey: AgentPreferences.enabledKey(.codex))
        #expect(await AgentTestSupport.eventually { provider.usableAgents == [.claude] })
    }

    @Test func aGenerationRunsWhatsChosen() async throws {
        defer { clean() }
        let provider = try await started()
        let setup = try #require(provider.generation())
        #expect(setup.kind == .claude)
        #expect(setup.label == "Claude Code · haiku")
        #expect(setup.style == CommitMessagePrompt.defaultStyle)
        #expect(setup.matchesStyle)
        #expect(!setup.showsPath)
        #expect(setup.agent == CommitMessageAgent(kind: .claude, executable: bin + "/claude", model: "haiku", effort: "low", extraArguments: [], timeLimit: .seconds(60)))

        let command = setup.command(worktree: "/work/api", hasDraft: false)
        #expect(command.executable == bin + "/claude")
        #expect(command.directory == "/work/api")
        #expect(command.environment == ["ROGA_GENERATING": "1"])
        #expect(command.arguments.prefix(6) == ["-p", "--safe-mode", "--model", "haiku", "--effort", "low"])
        #expect(command == CommitMessageCommand.command(for: setup.agent, worktree: "/work/api", style: CommitMessagePrompt.defaultStyle, hasDraft: false))
        #expect(setup.terminal(worktree: "/work/api", hasDraft: false) == [.comment("The staged changes go to its standard input"), .program(command, showsPath: false)])
    }

    @Test func aGenerationWithTheAgentsOwnDefaultsAndExtras() async throws {
        defer { clean() }
        let provider = try await started()
        defaults.set("", forKey: AgentPreferences.modelKey(.claude))
        defaults.set("high", forKey: AgentPreferences.effortKey(.claude))
        defaults.set("--append-system-prompt 'Use British spelling.'", forKey: AgentPreferences.extraArgumentsKey(.claude))
        defaults.set(30, forKey: AgentPreferences.timeLimitKey(.claude))
        defaults.set("Write in French.", forKey: AgentPreferences.instructionsKey)
        defaults.set(false, forKey: AgentPreferences.matchesStyleKey)
        provider.reloadSettings()

        let setup = try #require(provider.generation(with: .claude))
        #expect(setup.label == "Claude Code")
        #expect(setup.style == "Write in French.")
        #expect(!setup.matchesStyle)
        let command = setup.command(worktree: "/work/api", hasDraft: true)
        #expect(!command.arguments.contains("--model"))
        #expect(command.arguments.prefix(4) == ["-p", "--safe-mode", "--effort", "high"])
        #expect(command.timeout == .seconds(30))
        let prompt = try #require(command.arguments.firstIndex(of: "--system-prompt"))
        #expect(command.arguments[prompt + 1].hasSuffix("Write in French."))
        #expect(Array(command.arguments[(prompt + 2)...].prefix(3)) == ["--append-system-prompt", "Use British spelling.", "--"])
        #expect(command.arguments.last == CommitMessagePrompt.task(hasDraft: true))

        let codex = try #require(provider.generation(with: .codex))
        #expect(codex.label == "Codex")
        defaults.set("gpt-6-astra", forKey: AgentPreferences.modelKey(.codex))
        provider.reloadSettings()
        #expect(provider.generation(with: .codex)?.label == "Codex · gpt-6-astra")
    }

    @Test func readsCodexsDefaultModelFromItsFolder() async throws {
        defer { clean() }
        try """
            # Chosen in the Codex app.
            model = "gpt-6-astra"
            model_reasoning_effort = "medium"

            [profiles.work]
            model = "something-else"
            """.write(toFile: codexHome + "/config.toml", atomically: true, encoding: .utf8)
        let provider = try await started()
        #expect(provider.codexDefaultModel == "gpt-6-astra")
        #expect(provider.installer?.codexHome == codexHome)
    }

    @Test func readsOnlyTheTopLevelModel() {
        #expect(AgentProvider.codexDefaultModel(inConfiguration: "model = 'o5' # the default\n") == "o5")
        #expect(AgentProvider.codexDefaultModel(inConfiguration: "model_provider = \"x\"\nmodel=\"o5\"") == "o5")
        #expect(AgentProvider.codexDefaultModel(inConfiguration: "[profiles.a]\nmodel = \"o5\"") == nil)
        #expect(AgentProvider.codexDefaultModel(inConfiguration: "model = \"\"") == nil)
        #expect(AgentProvider.codexDefaultModel(inConfiguration: "") == nil)
    }

    @Test func choosingAProgramLooksAgainByItself() async throws {
        defer { clean() }
        let provider = try await started()
        defaults.set("/nonexistent/claude", forKey: AgentPreferences.programKey(.claude))
        provider.reloadSettings()
        #expect(await AgentTestSupport.eventually { provider.lookups[.claude] != nil })
        #expect(provider.lookups[.claude] == .configuredMissing("/nonexistent/claude"))
        #expect(provider.usableAgents == [.codex])
        // Codex wasn't looked for again.
        #expect(provider.installation(.codex) != nil)
    }

    @Test func installRunsTheCommandsItShowsAndChecksAgain() async throws {
        defer { clean() }
        let provider = try await started()
        let commands = try #require(provider.installCommands(.claude))
        #expect(commands.map(\.arguments).first == ["plugin", "marketplace", "add", support + "/plugins"])
        try "".write(toFile: log, atomically: true, encoding: .utf8)

        #expect(await provider.installHooks([.claude]))
        #expect(provider.hookWork[.claude] == nil)
        let runs = AgentTestSupport.runs(in: log)
        #expect(Array(runs.prefix(commands.count)) == commands.map(\.arguments))
        #expect(await AgentTestSupport.eventually { provider.hookStatus[.claude] != nil })
        #expect(runs.count >= commands.count)
    }

    @Test func aFailedInstallSaysWhatTheAgentSaid() async throws {
        defer { clean() }
        let provider = try await started(claudeBody: """
            if [ "$1" = "plugin" ] && [ "$2" = "install" ]; then echo 'Plugin "roga-hooks" not found in marketplace' >&2; exit 1; fi
            """)
        #expect(!(await provider.installHooks([.claude, .codex])))
        #expect(provider.hookWork[.claude] == .failed("Plugin \"roga-hooks\" not found in marketplace"))
        // Codex went on without it.
        #expect(provider.hookWork[.codex] == nil)
    }

    @Test func removeRunsItsCommands() async throws {
        defer { clean() }
        let provider = try await started()
        let commands = try #require(provider.removeCommands(.codex))
        try "".write(toFile: log, atomically: true, encoding: .utf8)
        #expect(await provider.removeHooks(.codex))
        #expect(Array(AgentTestSupport.runs(in: log).prefix(commands.count)) == commands.map(\.arguments))
    }

    @Test func aProgramTheNameWouldntFindShowsItsPath() async throws {
        defer { clean() }
        let provider = try await started()
        #expect(!provider.showsPath(bin + "/claude"))
        let elsewhere = try AgentTestSupport.folder()
        let other = try AgentTestSupport.script("exit 0", named: "claude", in: elsewhere)
        #expect(provider.showsPath(other))
    }

    @Test func theAppsOwnFoldersAreNamedAfterItsBundle() {
        #expect(AgentProvider.standardSupportFolder.lastPathComponent == (Bundle.main.bundleIdentifier ?? "sh.roga.app"))
    }
}
