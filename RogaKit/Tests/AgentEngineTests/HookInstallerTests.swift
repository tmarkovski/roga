import Darwin
import Foundation
import GitRunner
import Testing
@testable import AgentEngine

@Suite(.timeLimit(.minutes(1)))
struct HookInstallerTests {
    /// A support folder with a space in its path, like Application Support.
    func supportFolder() throws -> URL {
        try FakeAgent.folder().appending(path: "Application Support/sh.roga.test", directoryHint: .isDirectory)
    }

    /// An installer for a fake agent whose script is `body`, and the log of its runs.
    func fake(
        _ kind: AgentKind,
        _ body: String,
        codexHome: String? = nil,
        supportFolder chosen: URL? = nil
    ) throws -> (installer: HookInstaller, executable: String, log: String) {
        let folder = try FakeAgent.folder()
        let log = FakeAgent.path(folder) + "/runs"
        let executable = try FakeAgent.script(FakeAgent.recording(to: log, then: body), named: kind.executableName, in: folder)
        let installer = HookInstaller(programs: FakeAgent.programs, supportFolder: try chosen ?? supportFolder(), codexHome: codexHome ?? FakeAgent.path(folder) + "/codex-home")
        return (installer, executable, log)
    }

    /// The support folders of two copies of Roga with their own bundle IDs,
    /// side by side the way they are in Application Support, each with its
    /// plugin written.
    func twoCopies() throws -> (app: URL, dev: URL) {
        let folder = try FakeAgent.folder().appending(path: "Application Support", directoryHint: .isDirectory)
        let app = folder.appending(path: "sh.roga.app", directoryHint: .isDirectory)
        let dev = folder.appending(path: "sh.roga.dev", directoryHint: .isDirectory)
        for support in [app, dev] {
            try HookInstaller(programs: FakeAgent.programs, supportFolder: support)
                .writeFiles(helperPath: FakeAgent.path(support) + "/Roga.app/Contents/Helpers/roga")
        }
        return (app, dev)
    }

    /// A fake agent that prints `<itself>.json` when asked for its plugins and
    /// `<itself>.marketplaces.json` when asked for its marketplaces, and fails
    /// when the file isn't there.
    let listing = #"case "$2" in marketplace) cat "$0.marketplaces.json" ;; *) cat "$0.json" ;; esac"#

    // MARK: - Files

    @Test func writesThePluginAndTheLauncher() throws {
        let support = try supportFolder()
        let installer = HookInstaller(programs: FakeAgent.programs, supportFolder: support)
        try installer.writeFiles(helperPath: "/Applications/Roga.app/Contents/Helpers/roga")

        let launcher = FakeAgent.path(installer.launcher)
        #expect(launcher == FakeAgent.path(support) + "/bin/roga-hook")
        #expect(FakeAgent.path(installer.pluginsFolder) == FakeAgent.path(support) + "/plugins")
        for file in HookPlugin.files(launcher: launcher) {
            let path = FakeAgent.path(installer.pluginsFolder) + "/" + file.path
            #expect(FileManager.default.contents(atPath: path).map(Array.init) == file.contents, "\(file.path)")
            #expect(permissions(path) == 0o644)
        }
        #expect(FileManager.default.contents(atPath: launcher).map(Array.init)
            == HookPlugin.launcherScript(helperPath: "/Applications/Roga.app/Contents/Helpers/roga"))
        #expect(permissions(launcher) == 0o755)
        #expect(permissions(FakeAgent.path(support)) == 0o700)
    }

    @Test func writesAFileOnlyWhenItsBytesChange() throws {
        let installer = HookInstaller(programs: FakeAgent.programs, supportFolder: try supportFolder())
        try installer.writeFiles(helperPath: "/Applications/Roga.app/Contents/Helpers/roga")
        let launcher = FakeAgent.path(installer.launcher)
        let hooks = FakeAgent.path(installer.pluginsFolder) + "/roga-hooks/hooks/codex.json"
        let before = (fileNumber(hooks), fileNumber(launcher))

        try installer.writeFiles(helperPath: "/Applications/Roga.app/Contents/Helpers/roga")
        #expect(fileNumber(hooks) == before.0)
        #expect(fileNumber(launcher) == before.1)

        // Moving the app rewrites the launcher and leaves the plugin alone.
        try installer.writeFiles(helperPath: "/Users/me/Downloads/Roga.app/Contents/Helpers/roga")
        #expect(fileNumber(hooks) == before.0)
        #expect(fileNumber(launcher) != before.1)
        #expect(permissions(launcher) == 0o755)

        // A launcher someone made unexecutable is put right.
        chmod(launcher, 0o600)
        try installer.writeFiles(helperPath: "/Users/me/Downloads/Roga.app/Contents/Helpers/roga")
        #expect(permissions(launcher) == 0o755)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FakeAgent.path(installer.launcher.deletingLastPathComponent()))
        #expect(leftovers == ["roga-hook"])
    }

    @Test func theLauncherHandsTheEventToTheHelper() async throws {
        let folder = try FakeAgent.folder()
        let received = FakeAgent.path(folder) + "/received"
        let helper = try FakeAgent.script(
            "printf '%s|' \"$@\" > '\(received)'; cat >> '\(received)'",
            named: "roga",
            in: folder.appending(path: "Roga 2.app/Contents/Helpers")
        )
        let installer = HookInstaller(programs: FakeAgent.programs, supportFolder: try supportFolder())
        try installer.writeFiles(helperPath: helper)

        var command = ProgramCommand(FakeAgent.path(installer.launcher), ["hook", "--host", "claude", "--event", "Stop"])
        command.timeout = .seconds(10)
        let result = try await FakeAgent.programs.run(command, input: Array(#"{"session_id":"abc"}"#.utf8))
        #expect(result.succeeded)
        #expect(result.output.isEmpty)
        #expect(try String(contentsOfFile: received, encoding: .utf8) == #"hook|--host|claude|--event|Stop|{"session_id":"abc"}"#)
    }

    @Test func theLauncherReadsTheEventAndExitsQuietlyWhenTheHelperIsGone() async throws {
        let installer = HookInstaller(programs: FakeAgent.programs, supportFolder: try supportFolder())
        try installer.writeFiles(helperPath: "/nonexistent/Roga.app/Contents/Helpers/roga")
        var command = ProgramCommand(FakeAgent.path(installer.launcher), ["hook", "--host", "codex", "--event", "PreToolUse"])
        command.timeout = .seconds(10)
        let result = try await FakeAgent.programs.run(command, input: [UInt8](repeating: 0x61, count: 4 << 20))
        #expect(result.status == .exited(0))
        #expect(result.output.isEmpty)
        #expect(result.errorOutput.isEmpty)
    }

    // MARK: - Commands

    @Test func installsAndRemovesWithTheAgentsOwnPluginCommands() throws {
        let support = try supportFolder()
        let installer = HookInstaller(programs: FakeAgent.programs, supportFolder: support)
        let plugins = FakeAgent.path(support) + "/plugins"
        let claude = "/Users/me/.local/bin/claude"
        let codex = "/opt/homebrew/bin/codex"

        #expect(installer.installCommands(.claude, executable: claude).map(\.arguments) == [
            ["plugin", "marketplace", "add", plugins],
            ["plugin", "install", "roga-hooks@roga", "--scope", "user"],
            ["plugin", "update", "roga-hooks@roga", "--scope", "user"],
        ])
        #expect(installer.removeCommands(.claude, executable: claude).map(\.arguments) == [
            ["plugin", "uninstall", "roga-hooks@roga", "--scope", "user"],
            ["plugin", "marketplace", "remove", "roga"],
        ])
        #expect(installer.installCommands(.codex, executable: codex).map(\.arguments) == [
            ["plugin", "marketplace", "add", plugins],
            ["plugin", "add", "roga-hooks@roga"],
        ])
        #expect(installer.removeCommands(.codex, executable: codex).map(\.arguments) == [
            ["plugin", "remove", "roga-hooks@roga"],
            ["plugin", "marketplace", "remove", "roga"],
        ])
        #expect(installer.statusCommand(.claude, executable: claude).arguments == ["plugin", "list", "--json"])
        #expect(installer.statusCommand(.codex, executable: codex).arguments == ["plugin", "list", "--json"])

        let all = installer.installCommands(.claude, executable: claude) + installer.removeCommands(.codex, executable: codex)
        for command in all {
            #expect(command.priority == .normal)
            #expect(command.timeout == .seconds(60))
            #expect(command.directory == nil)
            #expect(command.environment.isEmpty)
        }
        #expect(installer.statusCommand(.codex, executable: codex).priority == .utility)
        #expect(installer.installCommands(.claude, executable: claude)[0].description
            == "/Users/me/.local/bin/claude plugin marketplace add '\(plugins)'")
    }

    @Test func givesCodexTheFolderItWasAskedToUse() throws {
        let installer = HookInstaller(programs: FakeAgent.programs, supportFolder: try supportFolder(), codexHome: "/tmp/codex-home")
        #expect(installer.codexHome == "/tmp/codex-home")
        for command in installer.installCommands(.codex, executable: "/opt/homebrew/bin/codex")
            + installer.removeCommands(.codex, executable: "/opt/homebrew/bin/codex")
            + [installer.statusCommand(.codex, executable: "/opt/homebrew/bin/codex")] {
            #expect(command.environment == ["CODEX_HOME": "/tmp/codex-home"])
        }
        #expect(installer.installCommands(.claude, executable: "/c").allSatisfy { $0.environment.isEmpty })

        let fromEnvironment = HookInstaller(
            programs: Programs(searchPath: "/usr/bin", inheritedEnvironment: ["CODEX_HOME": "/elsewhere"]),
            supportFolder: try supportFolder()
        )
        #expect(fromEnvironment.codexHome == "/elsewhere")
        #expect(fromEnvironment.installCommands(.codex, executable: "/c").allSatisfy { $0.environment.isEmpty })
        let byDefault = HookInstaller(programs: Programs(searchPath: "/usr/bin", inheritedEnvironment: [:]), supportFolder: try supportFolder())
        #expect(byDefault.codexHome == NSHomeDirectory() + "/.codex")
    }

    @Test func installRunsEachCommandInOrder() async throws {
        let (installer, claude, log) = try fake(.claude, "exit 0")
        try await installer.install(.claude, executable: claude)
        #expect(FakeAgent.runs(in: log) == installer.installCommands(.claude, executable: claude).map(\.arguments))

        let (codexInstaller, codex, codexLog) = try fake(.codex, #"echo "CODEX_HOME=$CODEX_HOME" >> "$0.environment""#)
        try await codexInstaller.install(.codex, executable: codex)
        #expect(FakeAgent.runs(in: codexLog) == [
            ["plugin", "marketplace", "add", FakeAgent.path(codexInstaller.pluginsFolder)],
            ["plugin", "add", "roga-hooks@roga"],
        ])
        #expect(try String(contentsOfFile: codex + ".environment", encoding: .utf8)
            == String(repeating: "CODEX_HOME=\(codexInstaller.codexHome)\n", count: 2))
    }

    @Test func installStopsAtTheFirstCommandThatFails() async throws {
        let message = #"✘ Failed to install plugin "roga-hooks@roga": Plugin "roga-hooks" not found in marketplace "roga"."#
        let (installer, claude, log) = try fake(.claude, """
            case "$2" in install) echo '\(message)' >&2; echo partial; exit 1 ;; esac
            """)
        let commands = installer.installCommands(.claude, executable: claude)
        await #expect(throws: HookInstallError.failed(commands[1], .exited(1), output: "partial\n", errorOutput: message + "\n")) {
            try await installer.install(.claude, executable: claude)
        }
        #expect(FakeAgent.runs(in: log).count == 2)
        let error = HookInstallError.failed(commands[1], .exited(1), output: "partial\n", errorOutput: message + "\n")
        #expect(error.message == message)
        #expect(error.description == "\(commands[1]) exited with status 1: \(message)")
        #expect(error.command == commands[1])
    }

    @Test func reportsAnAgentThatCrashesOrHangs() async throws {
        let (crashing, claude, _) = try fake(.claude, "echo 'dyld: Library not loaded' >&2; kill -ABRT $$")
        let command = crashing.installCommands(.claude, executable: claude)[0]
        await #expect(throws: HookInstallError.failed(command, .signaled(6), output: "", errorOutput: "dyld: Library not loaded\n")) {
            try await crashing.install(.claude, executable: claude)
        }

        let made = try fake(.codex, "sleep 30")
        var hanging = made.installer
        let codex = made.executable
        hanging.timeLimit = .milliseconds(300)
        let started = ContinuousClock.now
        do {
            try await hanging.install(.codex, executable: codex)
            Issue.record("A hanging install should fail")
        } catch HookInstallError.program(.timedOut(let timedOut, _, _)) {
            #expect(timedOut == hanging.installCommands(.codex, executable: codex)[0])
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await hanging.status(.codex, executable: "/nonexistent/codex") != .installed)
    }

    @Test func removeCountsWhatsAlreadyGoneAsRemoved() async throws {
        let (claudeInstaller, claude, claudeLog) = try fake(.claude, """
            case "$2" in
            uninstall) echo '✘ Failed to uninstall plugin "roga-hooks@roga": Plugin "roga-hooks@roga" not found in installed plugins' >&2; exit 1 ;;
            marketplace) echo "✘ Failed to remove marketplace: Marketplace 'roga' not found" >&2; exit 1 ;;
            esac
            """)
        try await claudeInstaller.remove(.claude, executable: claude)
        #expect(FakeAgent.runs(in: claudeLog) == claudeInstaller.removeCommands(.claude, executable: claude).map(\.arguments))

        let (codexInstaller, codex, codexLog) = try fake(.codex, """
            case "$2" in marketplace) echo 'Error: marketplace `roga` is not configured or installed' >&2; exit 1 ;; esac
            """)
        try await codexInstaller.remove(.codex, executable: codex)
        #expect(FakeAgent.runs(in: codexLog).count == 2)
    }

    @Test func removeStillReportsOtherFailures() async throws {
        let (installer, claude, log) = try fake(.claude, """
            case "$2" in uninstall) echo "✘ EACCES: permission denied, open '~/.claude/settings.json'" >&2; exit 1 ;; esac
            """)
        await #expect(throws: HookInstallError.self) {
            try await installer.remove(.claude, executable: claude)
        }
        #expect(FakeAgent.runs(in: log).count == 1)

        let (missing, codex, _) = try fake(.codex, "echo 'node: not found' >&2; exit 127")
        await #expect(throws: HookInstallError.self) {
            try await missing.remove(.codex, executable: codex)
        }
    }

    // MARK: - Status

    @Test func readsWhetherClaudeCodeHasThePlugin() async throws {
        let (installer, claude, log) = try fake(.claude, listing)
        let folder = FakeAgent.path(installer.pluginsFolder) + "/roga-hooks"
        let installed = #"[{"id":"other@market","enabled":false},{"id":"roga-hooks@roga","version":"1.0.0","scope":"user","enabled":true,"installPath":"/x","readFromFolder":"\#(folder)","projectEnabled":false}]"#
        func status(_ listing: String) async throws -> HookStatus {
            try listing.write(toFile: claude + ".json", atomically: true, encoding: .utf8)
            return await installer.status(.claude, executable: claude)
        }
        #expect(try await status(installed) == .installed)
        #expect(FakeAgent.runs(in: log).last == ["plugin", "list", "--json"])
        // The entries below are older Claude Code's, without `readFromFolder`,
        // and this one can't list its marketplaces, so the plugin's own answer stands.
        #expect(try await status("[]") == .notInstalled)
        #expect(try await status(#"[{"id":"roga-hooks@roga","enabled":false}]"#) == .disabled)
        #expect(try await status(#"[{"id":"roga-hooks@roga","scope":"project","enabled":false},{"id":"roga-hooks@roga","scope":"user","enabled":true}]"#) == .installed)
        #expect(try await status(#"[{"id":"roga-hooks@roga","enabled":true,"errors":["Marketplace roga failed to load: cache-miss"]}]"#)
            == .unknown("Marketplace roga failed to load: cache-miss"))
        #expect(try await status("Usage: claude plugin list") == .unknown("Claude Code listed its plugins in a way Roga couldn't read."))
    }

    @Test func saysWhenClaudeCodeReadsTheHooksFromAnotherCopy() async throws {
        // What Claude Code 2.1.318 listed after sh.roga.app installed and then
        // sh.roga.dev did: the marketplace, and so the plugin, is the second's.
        let (app, dev) = try twoCopies()
        func listed(readingFrom folder: String, enabled: Bool = true) -> String {
            """
            [
              {
                "id": "roga-hooks@roga",
                "version": "1.0.0",
                "scope": "user",
                "enabled": \(enabled),
                "installPath": "/Users/me/.claude/plugins/cache/roga/roga-hooks/1.0.0",
                "readFromFolder": "\(folder)",
                "folderVersion": "1.0.0",
                "installedAt": "2026-11-06T03:11:01.182Z",
                "lastUpdated": "2026-11-06T03:11:01.182Z",
                "projectEnabled": false
              }
            ]
            """
        }
        let devPlugins = FakeAgent.path(dev) + "/plugins"
        let (first, claude, log) = try fake(.claude, listing, supportFolder: app)
        let second = HookInstaller(programs: FakeAgent.programs, supportFolder: dev)
        func status(_ installer: HookInstaller, _ listing: String) async throws -> HookStatus {
            try listing.write(toFile: claude + ".json", atomically: true, encoding: .utf8)
            return await installer.status(.claude, executable: claude)
        }

        #expect(try await status(first, listed(readingFrom: devPlugins + "/roga-hooks")) == .anotherCopy(folder: devPlugins))
        #expect(try await status(second, listed(readingFrom: devPlugins + "/roga-hooks")) == .installed)
        // Turning on another copy's hooks wouldn't help this one either.
        #expect(try await status(first, listed(readingFrom: devPlugins + "/roga-hooks", enabled: false)) == .anotherCopy(folder: devPlugins))
        #expect(try await status(second, listed(readingFrom: devPlugins + "/roga-hooks", enabled: false)) == .disabled)
        // The listing names the folder, so the marketplaces aren't asked for.
        #expect(FakeAgent.runs(in: log).allSatisfy { $0 == ["plugin", "list", "--json"] })

        // A path through a symbolic link is still this copy's folder.
        let link = FakeAgent.path(try FakeAgent.folder()) + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: FakeAgent.path(dev))
        #expect(try await status(second, listed(readingFrom: link + "/plugins/roga-hooks")) == .installed)
        #expect(try await status(first, listed(readingFrom: link + "/plugins/roga-hooks")) == .anotherCopy(folder: link + "/plugins"))
        // So is a folder that's gone, written the same way.
        let gone = HookInstaller(programs: FakeAgent.programs, supportFolder: URL(filePath: "/nonexistent/sh.roga.gone", directoryHint: .isDirectory))
        #expect(try await status(gone, listed(readingFrom: "/nonexistent/sh.roga.gone/plugins/roga-hooks")) == .installed)
    }

    @Test func asksOlderClaudeCodeWhereItsMarketplaceIs() async throws {
        // Claude Code 2.1.286's answers after the same two installs: the plugin
        // list doesn't say which folder, and the marketplace list does.
        let (app, dev) = try twoCopies()
        let (first, claude, log) = try fake(.claude, listing, supportFolder: app)
        let second = HookInstaller(programs: FakeAgent.programs, supportFolder: dev)
        try """
            [
              {
                "id": "roga-hooks@roga",
                "version": "1.0.0",
                "scope": "user",
                "enabled": true,
                "installPath": "/Users/me/.claude/plugins/cache/roga/roga-hooks/1.0.0",
                "installedAt": "2026-11-06T03:18:45.117Z",
                "lastUpdated": "2026-11-06T03:18:45.117Z",
                "projectEnabled": false
              }
            ]
            """.write(toFile: claude + ".json", atomically: true, encoding: .utf8)
        func status(_ installer: HookInstaller, marketplaces: String?) async throws -> HookStatus {
            if let marketplaces {
                try marketplaces.write(toFile: claude + ".marketplaces.json", atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(atPath: claude + ".marketplaces.json")
            }
            return await installer.status(.claude, executable: claude)
        }
        let devPlugins = FakeAgent.path(dev) + "/plugins"
        let marketplaces = """
            [
              {
                "name": "roga",
                "source": "directory",
                "path": "\(devPlugins)",
                "installLocation": "\(devPlugins)"
              }
            ]
            """

        #expect(try await status(first, marketplaces: marketplaces) == .anotherCopy(folder: devPlugins))
        #expect(FakeAgent.runs(in: log).suffix(2) == [["plugin", "list", "--json"], ["plugin", "marketplace", "list", "--json"]])
        #expect(first.claudeMarketplacesCommand(executable: claude).priority == .utility)
        #expect(try await status(second, marketplaces: marketplaces) == .installed)
        #expect(try await status(first, marketplaces: #"[{"name":"other","source":"github","installLocation":"/x"}]"#) == .installed)
        // When Claude Code can't list its marketplaces, the plugin's own answer stands.
        #expect(try await status(first, marketplaces: nil) == .installed)

        // Nothing installed, nothing more to ask.
        try "[]".write(toFile: claude + ".json", atomically: true, encoding: .utf8)
        let before = FakeAgent.runs(in: log).count
        #expect(try await status(first, marketplaces: marketplaces) == .notInstalled)
        #expect(FakeAgent.runs(in: log).count == before + 1)
    }

    @Test func saysWhenClaudeCodeCantSay() async throws {
        let (installer, claude, _) = try fake(.claude, "echo 'error: unknown option --json' >&2; exit 1")
        #expect(await installer.status(.claude, executable: claude) == .unknown("error: unknown option --json"))
        #expect(await installer.status(.claude, executable: "/nonexistent/claude") != .installed)
    }

    @Test func readsWhetherCodexHasThePluginAndTrustsItsHooks() async throws {
        let (installer, codex, _) = try fake(.codex, "cat \"$0.json\"")
        try FileManager.default.createDirectory(atPath: installer.codexHome, withIntermediateDirectories: true)
        let configuration = installer.codexHome + "/config.toml"
        func status(_ listing: String, configuration text: String? = nil) async throws -> HookStatus {
            try listing.write(toFile: codex + ".json", atomically: true, encoding: .utf8)
            if let text {
                try text.write(toFile: configuration, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(atPath: configuration)
            }
            return await installer.status(.codex, executable: codex)
        }
        let listed = #"{"installed":[{"pluginId":"roga-hooks@roga","name":"roga-hooks","marketplaceName":"roga","version":"1.0.0","installed":true,"enabled":true}],"available":[]}"#
        let trusted = """
            [marketplaces.roga]
            source_type = "local"

            [plugins."roga-hooks@roga"]
            enabled = true

            [hooks.state]

            [hooks.state."roga-hooks@roga:hooks/codex.json:pre_tool_use:0:0"]
            trusted_hash = "sha256:0d9f"
            trusted_content_hash = "sha256:fa33"
            """
        #expect(try await status(listed, configuration: trusted) == .installed)
        #expect(try await status(listed, configuration: #"hooks.state = { "roga-hooks@roga:hooks/codex.json:stop:0:0" = { trusted_hash = "x" } }"#) == .installed)
        #expect(try await status(listed, configuration: #"[plugins."roga-hooks@roga"]"# + "\nenabled = true\n") == .needsTrust)
        #expect(try await status(listed) == .needsTrust)
        #expect(try await status(#"{"installed":[],"available":[]}"#, configuration: trusted) == .notInstalled)
        #expect(try await status(#"{"installed":[{"pluginId":"roga-hooks@roga","installed":true,"enabled":false}]}"#, configuration: trusted) == .disabled)
        #expect(try await status(#"{"installed":[{"pluginId":"roga-hooks@other","enabled":true}]}"#, configuration: trusted) == .notInstalled)
        #expect(try await status("[]") == .unknown("Codex listed its plugins in a way Roga couldn't read."))
    }

    @Test func saysWhenCodexRunsAnotherCopysHooks() async throws {
        // What Codex 0.166.0 listed after sh.roga.app installed and sh.roga.dev
        // tried to: Codex refused the second marketplace and kept the first's.
        let (app, dev) = try twoCopies()
        let appPlugins = FakeAgent.path(app) + "/plugins"
        let codexListing = """
            {
              "installed": [
                {
                  "pluginId": "roga-hooks@roga",
                  "name": "roga-hooks",
                  "marketplaceName": "roga",
                  "version": "1.0.0",
                  "installed": true,
                  "enabled": true,
                  "source": {
                    "source": "local",
                    "path": "\(appPlugins)/roga-hooks"
                  },
                  "marketplaceSource": {
                    "sourceType": "local",
                    "source": "\(appPlugins)"
                  },
                  "installPolicy": "AVAILABLE",
                  "authPolicy": "ON_INSTALL"
                }
              ],
              "available": []
            }
            """
        let (second, codex, _) = try fake(.codex, listing, supportFolder: dev)
        let first = HookInstaller(programs: FakeAgent.programs, supportFolder: app, codexHome: second.codexHome)
        try FileManager.default.createDirectory(atPath: second.codexHome, withIntermediateDirectories: true)
        try #"hooks.state = { "roga-hooks@roga:hooks/codex.json:stop:0:0" = { trusted_hash = "x" } }"#
            .write(toFile: second.codexHome + "/config.toml", atomically: true, encoding: .utf8)
        func status(_ installer: HookInstaller, _ listing: String) async throws -> HookStatus {
            try listing.write(toFile: codex + ".json", atomically: true, encoding: .utf8)
            return await installer.status(.codex, executable: codex)
        }

        // The trust is there, but it's in the other copy's hooks.
        #expect(try await status(second, codexListing) == .anotherCopy(folder: appPlugins))
        #expect(try await status(first, codexListing) == .installed)
        #expect(try await status(second, codexListing.replacing(#""enabled": true"#, with: #""enabled": false"#)) == .anotherCopy(folder: appPlugins))

        // Without the marketplace's folder, the plugin's own folder says it.
        let withoutMarketplace = #"{"installed":[{"pluginId":"roga-hooks@roga","installed":true,"enabled":true,"source":{"source":"local","path":"\#(appPlugins)/roga-hooks"}}]}"#
        #expect(try await status(second, withoutMarketplace) == .anotherCopy(folder: appPlugins))
        #expect(try await status(first, withoutMarketplace) == .installed)
    }

    // MARK: - Helpers

    func permissions(_ path: String) -> mode_t {
        var info = stat()
        guard stat(path, &info) == 0 else { return 0 }
        return info.st_mode & 0o777
    }

    func fileNumber(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int
    }
}
