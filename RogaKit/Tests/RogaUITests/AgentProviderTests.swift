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
        let provider = try await started(helperPath: helper)
        let manager = FileManager.default
        // Only the copy of Roga that hears the hooks writes them.
        #expect(!manager.fileExists(atPath: support + "/bin/roga-hook"))
        provider.pointTheHooksHere()
        #expect(await AgentTestSupport.eventually { manager.isExecutableFile(atPath: support + "/bin/roga-hook") })
        #expect(manager.fileExists(atPath: support + "/plugins/.claude-plugin/marketplace.json"))
        #expect(manager.fileExists(atPath: support + "/plugins/roga-hooks/hooks/hooks.json"))
        #expect(manager.fileExists(atPath: support + "/plugins/roga-hooks/hooks/codex.json"))
        let launcher = try String(contentsOfFile: support + "/bin/roga-hook", encoding: .utf8)
        #expect(launcher.contains(helper))
    }

    @Test func writesThePluginOnceGitIsReadyWhenItAlreadyHearsTheHooks() async throws {
        defer { clean() }
        let helper = try AgentTestSupport.script("exit 0", named: "roga", in: bin)
        try AgentTestSupport.claude(in: bin, log: log)
        let provider = AgentTestSupport.provider(support: support, helperPath: helper, defaults: defaults, codexHome: codexHome)
        provider.pointTheHooksHere()
        #expect(!FileManager.default.fileExists(atPath: support + "/bin/roga-hook"))
        provider.start(git: try await AgentTestSupport.git(searchPath: bin))
        #expect(await AgentTestSupport.eventually { FileManager.default.isExecutableFile(atPath: support + "/bin/roga-hook") })
    }

    @Test func writesNothingWithoutAHelper() async throws {
        defer { clean() }
        let provider = try await started()
        provider.pointTheHooksHere()
        try await Task.sleep(for: .milliseconds(100))
        #expect(provider.helperPath == nil)
        #expect(!FileManager.default.fileExists(atPath: support + "/plugins"))
        #expect(!FileManager.default.fileExists(atPath: support + "/bin"))
        #expect(provider.pluginFilesError == nil)
    }

    @Test func onlyTheCopyThatHearsTheHooksPointsTheLauncherAtItself() async throws {
        defer { clean() }
        // Two copies of Roga with the same bundle ID, such as a build from
        // Xcode and the copy in Applications, share the support folder.
        try AgentTestSupport.claude(in: bin, log: log)
        let folder = (bin as NSString).deletingLastPathComponent
        let heardByA = folder + "/heard-by-a"
        let helperA = try AgentTestSupport.script("/bin/cat > /dev/null; echo \"$@\" >> '\(heardByA)'", named: "roga", in: try AgentTestSupport.folder())
        let helperB = try AgentTestSupport.script("/bin/cat > /dev/null", named: "roga", in: try AgentTestSupport.folder())
        let git = try await AgentTestSupport.git(searchPath: bin)
        let supportURL = URL(filePath: support, directoryHint: .isDirectory)
        let launcher = support + "/bin/roga-hook"

        let a = AgentTestSupport.provider(support: support, helperPath: helperA, defaults: defaults, codexHome: codexHome)
        let monitorA = AgentMonitor(supportFolder: supportURL, checkInterval: nil)
        a.start(git: git)
        monitorA.start(agents: a)
        defer { monitorA.stop() }
        #expect(monitorA.listening == .listening)
        #expect(await AgentTestSupport.eventually { (try? String(contentsOfFile: launcher, encoding: .utf8))?.contains(helperA) == true })

        // The second copy can't take the socket, so it leaves the launcher
        // pointing at the copy that can.
        let (defaultsB, defaultsBName) = AgentTestSupport.defaults()
        defer { AgentTestSupport.remove(defaultsB, named: defaultsBName) }
        let b = AgentTestSupport.provider(support: support, helperPath: helperB, defaults: defaultsB, codexHome: codexHome)
        let monitorB = AgentMonitor(supportFolder: supportURL, checkInterval: nil)
        b.start(git: git)
        monitorB.start(agents: b)
        defer { monitorB.stop() }
        #expect(monitorB.listening == .anotherCopy)
        #expect(await AgentTestSupport.eventually { !b.isLooking })
        try await Task.sleep(for: .milliseconds(100))
        #expect(try String(contentsOfFile: launcher, encoding: .utf8).contains(helperA))
        // A hook still reaches the copy that listens.
        let programs = Programs(searchPath: bin)
        let result = try await programs.run(ProgramCommand(launcher, ["hook", "--host", "claude", "--event", "Stop"]), input: Array("{}".utf8))
        #expect(result.succeeded)
        #expect(FileManager.default.fileExists(atPath: heardByA))

        // Once the first copy quits, Try Again in the second takes the
        // socket, and the launcher with it.
        monitorA.stop()
        #expect(await AgentTestSupport.eventually {
            monitorB.start(agents: b)
            return monitorB.listening == .listening
        })
        #expect(await AgentTestSupport.eventually { (try? String(contentsOfFile: launcher, encoding: .utf8))?.contains(helperB) == true })
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
        #expect(command.arguments.prefix(8) == ["-p", "--safe-mode", "--setting-sources", "user", "--model", "haiku", "--effort", "low"])
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
        #expect(command.arguments.prefix(6) == ["-p", "--safe-mode", "--setting-sources", "user", "--effort", "high"])
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
        #expect(provider.codexMCPServers.isEmpty)
    }

    @Test func aGenerationWithCodexTurnsOffItsMCPServers() async throws {
        defer { clean() }
        try """
            model = "gpt-6-astra"

            [mcp_servers.node_repl]
            command = "node"
            startup_timeout_sec = 120

            [mcp_servers.docs]
            url = "https://example.com/mcp"
            """.write(toFile: codexHome + "/config.toml", atomically: true, encoding: .utf8)
        let provider = try await started()
        #expect(provider.codexMCPServers == ["node_repl", "docs"])
        let setup = try #require(provider.generation(with: .codex))
        #expect(setup.agent.mcpServers == ["node_repl", "docs"])
        #expect(setup.agent.codexConfigurationFile == codexHome + "/config.toml")
        let arguments = setup.command(worktree: "/work/api", hasDraft: false).arguments
        #expect(arguments.contains("mcp_servers.node_repl.enabled=false"))
        #expect(arguments.contains("mcp_servers.docs.enabled=false"))
        // Claude Code turns its own off with --safe-mode.
        let claude = try #require(provider.generation(with: .claude))
        #expect(claude.agent.mcpServers.isEmpty && claude.agent.codexConfigurationFile == nil)
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
        // Claude Code lists Roga's plugin once it has been installed.
        let installed = (bin as NSString).deletingLastPathComponent + "/installed"
        let provider = try await started(claudeBody: """
            if [ "$1" = "plugin" ] && [ "$2" = "install" ]; then : > '\(installed)'; fi
            if [ "$1" = "plugin" ] && [ "$2" = "list" ] && [ -f '\(installed)' ]; then
                echo '[{"id":"\(HookPlugin.pluginID)","enabled":true,"readFromFolder":"\(support)/plugins/\(HookPlugin.pluginName)"}]'
                exit 0
            fi
            """)
        #expect(provider.hookStatus[.claude] == .notInstalled)
        let commands = try #require(provider.installCommands(.claude))
        #expect(commands.map(\.arguments).first == ["plugin", "marketplace", "add", support + "/plugins"])
        try "".write(toFile: log, atomically: true, encoding: .utf8)

        #expect(await provider.installHooks([.claude]))
        #expect(provider.hookWork[.claude] == nil)
        #expect(await AgentTestSupport.eventually { provider.hookStatus[.claude] == .installed })
        let runs = AgentTestSupport.runs(in: log)
        #expect(Array(runs.prefix(commands.count)) == commands.map(\.arguments))
        #expect(runs.dropFirst(commands.count).contains(["plugin", "list", "--json"]))
    }

    @Test func aFailedInstallSaysWhatTheAgentSaid() async throws {
        defer { clean() }
        let provider = try await started(claudeBody: """
            if [ "$1" = "plugin" ] && [ "$2" = "install" ]; then echo 'Plugin "roga-hooks" not found in marketplace' >&2; exit 1; fi
            """)
        #expect(!(await provider.installHooks([.claude, .codex])))
        #expect(provider.hookWork[.claude] == .failed(.install, "Plugin \"roga-hooks\" not found in marketplace"))
        // Codex went on without it.
        #expect(provider.hookWork[.codex] == nil)
    }

    /// A provider with the fake Claude Code and a fake Codex that lists Roga's
    /// plugin, trusted, while `listed` holds, and fails the command `failing`
    /// with `words`. When `recording` is given, the fake Codex records its
    /// runs in the log too, and then runs it.
    private func startedWithCodex(listed: String, failing: String, words: String, recording: String? = nil) async throws -> AgentProvider {
        let folder = (bin as NSString).deletingLastPathComponent
        try AgentTestSupport.claude(in: bin, log: log)
        try AgentTestSupport.script("""
            if [ "$1" = "--version" ]; then echo 'codex-cli 0.166.0'; exit 0; fi
            \(recording.map { AgentTestSupport.recording(to: log) + "\n" + $0 } ?? "")
            if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
                if \(listed); then
                    echo '{"installed":[{"pluginId":"\(HookPlugin.pluginID)","installed":true,"enabled":true}]}'
                else
                    echo '{"installed":[]}'
                fi
                exit 0
            fi
            if [ "$1 $2" = '\(failing)' ]; then echo '\(words)' >&2; exit 1; fi
            exit 0
            """, named: "codex", in: bin)
        try "[hooks.state.\"\(HookPlugin.pluginID):\(HookPlugin.codexHooksPath):stop:0:0\"]\ntrusted = true\n"
            .write(toFile: codexHome + "/config.toml", atomically: true, encoding: .utf8)
        let helper = try AgentTestSupport.script("exit 0", named: "roga", in: folder)
        let provider = AgentTestSupport.provider(support: support, helperPath: helper, defaults: defaults, codexHome: codexHome)
        provider.start(git: try await AgentTestSupport.git(searchPath: bin))
        #expect(await AgentTestSupport.eventually { !provider.isLooking && provider.hookStatus.count == 2 })
        return provider
    }

    @Test func aFailureOutlivesTheStatusReadRightAfterIt() async throws {
        defer { clean() }
        // The plugin is there, but adding it again fails, so the status
        // right after reads installed, which no longer offers Install.
        let provider = try await startedWithCodex(listed: "true", failing: "plugin add", words: "Error: plugin cache is locked")
        #expect(provider.hookStatus[.codex] == .installed)
        #expect(!(await provider.installHooks([.codex])))
        #expect(provider.hookWork[.codex] == .failed(.install, "Error: plugin cache is locked"))
        #expect(await AgentTestSupport.eventually { provider.hookStatus[.codex] == .installed })
        #expect(provider.hookWork[.codex] == .failed(.install, "Error: plugin cache is locked"))
        // A later look at the status sends it away.
        provider.refreshHookStatus()
        #expect(await AgentTestSupport.eventually { provider.hookStatus[.codex] == .installed })
        #expect(provider.hookWork[.codex] == nil)
    }

    @Test func aFailedRemoveGoesOnceTheHooksAreGone() async throws {
        defer { clean() }
        let gone = (bin as NSString).deletingLastPathComponent + "/gone"
        let provider = try await startedWithCodex(listed: "[ ! -f '\(gone)' ]", failing: "plugin remove", words: "Error: permission denied")
        #expect(!(await provider.removeHooks(.codex)))
        #expect(await AgentTestSupport.eventually { provider.hookStatus[.codex] == .installed })
        // Still installed, so Remove is still offered, and the failure stays.
        provider.refreshHookStatus()
        #expect(await AgentTestSupport.eventually { provider.hookStatus[.codex] == .installed })
        #expect(provider.hookWork[.codex] == .failed(.remove, "Error: permission denied"))
        // Someone removed the plugin in Terminal.
        try "".write(toFile: gone, atomically: true, encoding: .utf8)
        provider.refreshHookStatus()
        #expect(await AgentTestSupport.eventually { provider.hookStatus[.codex] == .notInstalled })
        #expect(provider.hookWork[.codex] == nil)
    }

    @Test func lookingAgainForgetsWhatFailed() async throws {
        defer { clean() }
        let provider = try await startedWithCodex(listed: "false", failing: "plugin add", words: "Error: plugin cache is locked")
        #expect(!(await provider.installHooks([.codex])))
        #expect(await AgentTestSupport.eventually { provider.hookStatus[.codex] == .notInstalled })
        provider.refreshHookStatus()
        #expect(await AgentTestSupport.eventually { provider.hookStatus[.codex] == .notInstalled })
        // Not installed still offers Install, so the failure stays until
        // someone looks again.
        #expect(provider.hookWork[.codex] == .failed(.install, "Error: plugin cache is locked"))
        provider.lookAgain()
        #expect(provider.hookWork[.codex] == nil)
    }

    @Test func eachStatusOffersWhatTheHooksButtonDoes() {
        #expect(AgentProvider.offeredAction(.notInstalled, for: .claude) == .install)
        #expect(AgentProvider.offeredAction(.unknown("no"), for: .codex) == .install)
        for status: HookStatus in [.installed, .needsTrust, .disabled] {
            #expect(AgentProvider.offeredAction(status, for: .claude) == .remove)
        }
        // Claude Code takes another copy's hooks over; Codex removes them first.
        #expect(AgentProvider.offeredAction(.anotherCopy(folder: "/x"), for: .claude) == .install)
        #expect(AgentProvider.offeredAction(.anotherCopy(folder: "/x"), for: .codex) == .remove)
    }

    @Test func removeRunsItsCommandsAndChecksAgain() async throws {
        defer { clean() }
        // Codex lists Roga's plugin, trusted, until it's removed.
        let removed = (bin as NSString).deletingLastPathComponent + "/removed"
        let provider = try await startedWithCodex(listed: "[ ! -f '\(removed)' ]", failing: "none", words: "", recording: """
            if [ "$1" = "plugin" ] && [ "$2" = "remove" ]; then : > '\(removed)'; fi
            """)
        #expect(provider.hookStatus[.codex] == .installed)
        let commands = try #require(provider.removeCommands(.codex))
        try "".write(toFile: log, atomically: true, encoding: .utf8)
        #expect(await provider.removeHooks(.codex))
        #expect(await AgentTestSupport.eventually { provider.hookStatus[.codex] == .notInstalled })
        let runs = AgentTestSupport.runs(in: log).filter { $0.first == "plugin" }
        #expect(Array(runs.prefix(commands.count)) == commands.map(\.arguments))
        #expect(runs.dropFirst(commands.count).contains(["plugin", "list", "--json"]))
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
