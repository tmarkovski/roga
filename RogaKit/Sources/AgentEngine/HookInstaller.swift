import Darwin
import Foundation
import GitRunner

/// Whether an agent runs Roga's hooks, as far as the agent says.
public enum HookStatus: Sendable, Hashable {
    case notInstalled
    case installed
    /// The plugin is installed, but someone turned it off in the agent.
    case disabled
    /// Codex has the plugin, but none of its hooks are trusted yet, so Codex
    /// doesn't run them. People trust them in Codex's `/hooks`, or with
    /// "Review hooks" in the Codex app.
    case needsTrust
    /// The agent runs Roga's hooks from another copy of Roga, one with another
    /// bundle ID and so another support folder, so they reach that copy and
    /// this one hears nothing. `folder` is that copy's plugins folder, as the
    /// agent recorded it.
    ///
    /// Every copy's marketplace is called `roga`, so an agent knows only one
    /// of them at a time. Installing from this copy takes the hooks over in
    /// Claude Code, which points the marketplace at the new folder. Codex
    /// refuses, saying the marketplace is "already added from a different
    /// source", so there Remove has to come first.
    case anotherCopy(folder: String)
    /// The agent couldn't say, for this reason.
    case unknown(String)
}

/// Why installing or removing Roga's hooks didn't work.
public enum HookInstallError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A command exited with a status other than 0, or a signal stopped it.
    case failed(ProgramCommand, ExitStatus, output: String, errorOutput: String)
    /// A command couldn't be started, ran past its time limit or printed too much.
    case program(ProgramError)

    public var command: ProgramCommand {
        switch self {
        case .failed(let command, _, _, _): command
        case .program(let error): error.command
        }
    }

    public var description: String {
        switch self {
        case .failed(let command, let status, _, _):
            "\(command) \(status)" + (said.isEmpty ? "." : ": \(said)")
        case .program(let error):
            error.description
        }
    }

    /// What to tell someone who asked for it: what the agent said, which
    /// usually says what to do about it, or `description` if it said nothing.
    public var message: String {
        said.isEmpty ? description : said
    }

    /// What the agent printed about it, from standard error first, since that's
    /// where both agents explain a failure.
    private var said: String {
        guard case .failed(_, _, let output, let errorOutput) = self else { return "" }
        let error = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return error.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : error
    }
}

/// Installs, removes and checks Roga's hooks in Claude Code and Codex, through
/// their own `plugin` commands (decision 41).
///
/// Roga never edits an agent's settings itself. The agents' commands know how
/// their files fit together, and Roga can show the exact commands it runs
/// (decision 29), so anyone can run them or undo them in a terminal.
public struct HookInstaller: Sendable {
    public let programs: Programs
    /// Roga's folder in Application Support, `~/Library/Application Support/<bundle id>`.
    public let supportFolder: URL
    /// The folder Codex keeps its configuration in, where Roga looks for the
    /// hooks people have trusted.
    public let codexHome: String
    /// The Codex folder that was asked for, which Codex's commands then get as
    /// `CODEX_HOME`. Without one they use Codex's own default, as `codexHome` does.
    let chosenCodexHome: String?
    /// How long installing or removing may take for each command.
    var timeLimit = Duration.seconds(60)
    /// How long asking an agent for its plugins may take.
    var statusTimeLimit = Duration.seconds(15)

    /// - Parameter codexHome: Codex's folder, or nil for `CODEX_HOME` in the
    ///   programs' environment, or else `~/.codex`.
    public init(programs: Programs, supportFolder: URL, codexHome: String? = nil) {
        self.programs = programs
        self.supportFolder = supportFolder
        self.chosenCodexHome = codexHome
        self.codexHome = codexHome
            ?? programs.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.codex"
    }

    /// The plugin folder, which is also the `roga` marketplace both agents add.
    public var pluginsFolder: URL {
        supportFolder.appending(path: "plugins", directoryHint: .isDirectory)
    }

    /// The script every hook runs.
    public var launcher: URL {
        supportFolder.appending(path: "bin", directoryHint: .isDirectory).appending(path: "roga-hook")
    }

    // MARK: - Files

    /// Writes the plugin and the launcher, pointing the launcher at the helper
    /// inside the running app. Roga calls it at every launch, since the app may
    /// have moved.
    ///
    /// A file is only written when its bytes change, because Codex pins its
    /// trust to the plugin's contents and Claude Code reads the plugin from
    /// this folder when a session starts. Each file is replaced in one step, so
    /// an agent never reads half of one, and the launcher is executable before
    /// it takes the old one's place.
    public func writeFiles(helperPath: String) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: Self.plainPath(supportFolder)) {
            // Only this user's processes have any business in it, and the
            // hooks' socket goes here too.
            try manager.createDirectory(at: supportFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for file in HookPlugin.files(launcher: Self.plainPath(launcher)) {
            try Self.write(file.contents, to: pluginsFolder.appending(path: file.path), permissions: 0o644)
        }
        try Self.write(HookPlugin.launcherScript(helperPath: helperPath), to: launcher, permissions: 0o755)
    }

    static func write(_ bytes: [UInt8], to url: URL, permissions: mode_t) throws {
        let manager = FileManager.default
        let path = plainPath(url)
        var info = stat()
        if let existing = manager.contents(atPath: path), existing.elementsEqual(bytes) {
            if stat(path, &info) == 0, info.st_mode & 0o777 != permissions {
                try manager.setAttributes([.posixPermissions: Int(permissions)], ofItemAtPath: path)
            }
            return
        }
        let folder = url.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = plainPath(folder) + "/.\(url.lastPathComponent).\(UUID().uuidString)"
        guard manager.createFile(atPath: temporary, contents: Data(bytes), attributes: [.posixPermissions: Int(permissions)]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary])
        }
        guard rename(temporary, path) == 0 else {
            let code = errno
            unlink(temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    // MARK: - Commands

    /// The exact commands Install runs, in order, for showing them (decision
    /// 29) and running them.
    ///
    /// Adding the marketplace from this folder again succeeds in both agents,
    /// and so does installing a plugin that's installed. So Install also
    /// repairs: Codex copies the plugin again, and Claude Code's `update`
    /// records a newer version once `HookPlugin.version` goes up. When another
    /// copy of Roga added the marketplace from its own folder, Claude Code
    /// points it at this one instead, but Codex's `marketplace add` fails until
    /// the other copy's is removed (see `HookStatus.anotherCopy`).
    public func installCommands(_ kind: AgentKind, executable: String) -> [ProgramCommand] {
        let folder = Self.plainPath(pluginsFolder)
        switch kind {
        case .claude:
            return [
                command(kind, executable, ["plugin", "marketplace", "add", folder]),
                command(kind, executable, ["plugin", "install", HookPlugin.pluginID, "--scope", "user"]),
                command(kind, executable, ["plugin", "update", HookPlugin.pluginID, "--scope", "user"]),
            ]
        case .codex:
            return [
                command(kind, executable, ["plugin", "marketplace", "add", folder]),
                command(kind, executable, ["plugin", "add", HookPlugin.pluginID]),
            ]
        }
    }

    /// The exact commands Remove runs, in order. Removing the marketplace
    /// after the plugin leaves nothing of Roga's in the agent.
    public func removeCommands(_ kind: AgentKind, executable: String) -> [ProgramCommand] {
        switch kind {
        case .claude:
            [
                command(kind, executable, ["plugin", "uninstall", HookPlugin.pluginID, "--scope", "user"]),
                command(kind, executable, ["plugin", "marketplace", "remove", HookPlugin.marketplaceName]),
            ]
        case .codex:
            [
                command(kind, executable, ["plugin", "remove", HookPlugin.pluginID]),
                command(kind, executable, ["plugin", "marketplace", "remove", HookPlugin.marketplaceName]),
            ]
        }
    }

    /// The command that lists the agent's plugins, which `status` reads.
    public func statusCommand(_ kind: AgentKind, executable: String) -> ProgramCommand {
        asking(kind, executable, ["plugin", "list", "--json"])
    }

    /// The command that lists Claude Code's marketplaces and their folders.
    /// `status` runs it only for versions before 2.1.289, whose plugin list
    /// doesn't say which folder the plugin is read from.
    func claudeMarketplacesCommand(executable: String) -> ProgramCommand {
        asking(.claude, executable, ["plugin", "marketplace", "list", "--json"])
    }

    /// A command that only asks the agent something, so it runs at utility
    /// priority and with the shorter time limit.
    private func asking(_ kind: AgentKind, _ executable: String, _ arguments: [String]) -> ProgramCommand {
        var command = command(kind, executable, arguments)
        command.priority = .utility
        command.timeout = statusTimeLimit
        return command
    }

    private func command(_ kind: AgentKind, _ executable: String, _ arguments: [String]) -> ProgramCommand {
        var command = ProgramCommand(executable, arguments)
        command.timeout = timeLimit
        if kind == .codex, let chosenCodexHome {
            command.environment["CODEX_HOME"] = chosenCodexHome
        }
        return command
    }

    // MARK: - Running them

    /// Runs `installCommands` in order, and stops at the first that fails.
    ///
    /// - Throws: `HookInstallError` with the failing command and what it
    ///   printed, or `CancellationError`.
    @concurrent
    public func install(_ kind: AgentKind, executable: String) async throws {
        for command in installCommands(kind, executable: executable) {
            try await run(command, toleratingAbsence: false)
        }
    }

    /// Runs `removeCommands` in order. A command that fails because the plugin
    /// or the marketplace is already gone counts as done, so Remove works
    /// however much of an install is left.
    ///
    /// - Throws: `HookInstallError` with the failing command and what it
    ///   printed, or `CancellationError`.
    @concurrent
    public func remove(_ kind: AgentKind, executable: String) async throws {
        for command in removeCommands(kind, executable: executable) {
            try await run(command, toleratingAbsence: true)
        }
    }

    /// Asks the agent whether it has Roga's plugin, whether it reads it from
    /// this copy's folder, and whether it's turned on. For Codex it also looks
    /// in `config.toml` for trust in any of the plugin's hooks, since Codex
    /// runs only the hooks people have trusted.
    ///
    /// The trust check is a plain search for the plugin's hook keys, such as
    /// `"roga-hooks@roga:hooks/codex.json:stop:0:0"`. It can't tell a trust
    /// that a changed plugin has outgrown, because Codex hashes the plugin's
    /// contents in its own way.
    @concurrent
    public func status(_ kind: AgentKind, executable: String) async -> HookStatus {
        let command = statusCommand(kind, executable: executable)
        let result: ProgramResult
        do {
            result = try await programs.run(command)
        } catch let error as ProgramError {
            return .unknown(HookInstallError.program(error).message)
        } catch {
            return .unknown("Roga stopped asking \(kind.name) about its plugins.")
        }
        guard result.succeeded else {
            return .unknown(HookInstallError.failed(command, result.status, output: result.text, errorOutput: result.errorOutput).message)
        }
        let folder = Self.plainPath(pluginsFolder)
        switch kind {
        case .claude:
            return await Self.claudeStatus(listing: result.output, pluginsFolder: folder) {
                await claudeMarketplaceFolder(executable: executable)
            }
        case .codex:
            let listed = Self.codexStatus(listing: result.output, pluginsFolder: folder)
            guard listed == .installed else { return listed }
            let configuration = (try? String(contentsOfFile: codexHome + "/config.toml", encoding: .utf8)) ?? ""
            return Self.codexTrustsHooks(configuration) ? .installed : .needsTrust
        }
    }

    /// The folder of Claude Code's `roga` marketplace, or nil when Claude Code
    /// can't say, in which case `status` keeps the answer it had.
    private func claudeMarketplaceFolder(executable: String) async -> String? {
        guard let result = try? await programs.run(claudeMarketplacesCommand(executable: executable)),
              result.succeeded
        else { return nil }
        return Self.claudeMarketplaceFolder(listing: result.output)
    }

    private func run(_ command: ProgramCommand, toleratingAbsence: Bool) async throws {
        let result: ProgramResult
        do {
            result = try await programs.run(command)
        } catch let error as ProgramError {
            throw HookInstallError.program(error)
        }
        if result.succeeded { return }
        if toleratingAbsence, case .exited = result.status, Self.saysAlreadyGone(result) { return }
        throw HookInstallError.failed(command, result.status, output: result.text, errorOutput: result.errorOutput)
    }

    // MARK: - Reading what the agents print

    /// Whether a failed removal failed because there was nothing to remove.
    /// Claude Code says `Plugin "roga-hooks@roga" not found in installed
    /// plugins` and `Marketplace 'roga' not found`, and Codex says
    /// ``marketplace `roga` is not configured or installed``. Codex's plugin
    /// removal succeeds either way. The name has to be there too, so that a
    /// tool that couldn't find something else, such as a program it needs,
    /// still counts as a failure.
    static func saysAlreadyGone(_ result: ProgramResult) -> Bool {
        let text = (result.text + "\n" + result.errorOutput).lowercased()
        return text.contains(HookPlugin.marketplaceName)
            && ["not found", "not installed", "not configured"].contains { text.contains($0) }
    }

    /// Reads `claude plugin list --json`, an array of plugins such as
    /// `{"id":"roga-hooks@roga","version":"1.0.0","scope":"user","enabled":true,…}`.
    /// An entry can also carry `errors`, as when its marketplace folder is
    /// missing, and then its hooks don't run.
    ///
    /// Claude Code reads the plugin from the marketplace's folder, which
    /// belongs to another copy of Roga when that copy installed last. From
    /// 2.1.289 the entry says so, as `readFromFolder`, the plugin's own folder
    /// inside the marketplace. Earlier versions read the marketplace's folder
    /// as well (2.1.250's and 2.1.286's `plugin details` count the hooks there,
    /// not in the copy in their cache), but only their marketplace list says
    /// where it is, so `marketplaceFolder` is asked for it only then.
    static func claudeStatus(
        listing: [UInt8],
        pluginsFolder: String,
        marketplaceFolder: () async -> String?
    ) async -> HookStatus {
        guard let plugins = (try? JSONSerialization.jsonObject(with: Data(listing))) as? [Any] else {
            return .unknown("Claude Code listed its plugins in a way Roga couldn't read.")
        }
        let ours = plugins.compactMap { $0 as? [String: Any] }.filter { $0["id"] as? String == HookPlugin.pluginID }
        guard let entry = ours.first(where: { $0["enabled"] as? Bool == true }) ?? ours.first else {
            return .notInstalled
        }
        // Whose the hooks are matters more than whether they're turned on:
        // turning on another copy's hooks wouldn't tell this one anything.
        if let read = entry["readFromFolder"] as? String {
            if !sameFolder(read, pluginsFolder + "/" + HookPlugin.pluginName) {
                return .anotherCopy(folder: (read as NSString).deletingLastPathComponent)
            }
        } else if let marketplace = await marketplaceFolder(), !sameFolder(marketplace, pluginsFolder) {
            return .anotherCopy(folder: marketplace)
        }
        guard entry["enabled"] as? Bool == true else { return .disabled }
        if let error = (entry["errors"] as? [Any])?.compactMap({ $0 as? String }).first {
            return .unknown(error)
        }
        return .installed
    }

    /// Reads `claude plugin marketplace list --json`, an array such as
    /// `[{"name":"roga","source":"directory","path":"…/plugins","installLocation":"…/plugins"}]`,
    /// for the folder of the `roga` marketplace.
    static func claudeMarketplaceFolder(listing: [UInt8]) -> String? {
        guard let marketplaces = (try? JSONSerialization.jsonObject(with: Data(listing))) as? [Any] else { return nil }
        let ours = marketplaces.compactMap { $0 as? [String: Any] }.first { $0["name"] as? String == HookPlugin.marketplaceName }
        return ours.flatMap { $0["path"] as? String ?? $0["installLocation"] as? String }
    }

    /// Reads `codex plugin list --json`, which is
    /// `{"installed":[{"pluginId":"roga-hooks@roga","installed":true,"enabled":true,"source":{"source":"local","path":"…/plugins/roga-hooks"},"marketplaceSource":{"sourceType":"local","source":"…/plugins"},…}],"available":[…]}`.
    /// The answer is at most `installed`, since trust is in `config.toml`.
    ///
    /// Codex copies the plugin from the marketplace's folder into its own
    /// cache, and keeps the folder of whichever copy of Roga added the
    /// marketplace first, since it refuses to add another.
    static func codexStatus(listing: [UInt8], pluginsFolder: String) -> HookStatus {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(listing))) as? [String: Any],
              let installed = object["installed"] as? [Any]
        else {
            return .unknown("Codex listed its plugins in a way Roga couldn't read.")
        }
        let ours = installed.compactMap { $0 as? [String: Any] }.first {
            $0["pluginId"] as? String == HookPlugin.pluginID && $0["installed"] as? Bool != false
        }
        guard let ours else { return .notInstalled }
        let marketplace = (ours["marketplaceSource"] as? [String: Any])?["source"] as? String
            ?? ((ours["source"] as? [String: Any])?["path"] as? String).map { ($0 as NSString).deletingLastPathComponent }
        if let marketplace, marketplace.hasPrefix("/"), !sameFolder(marketplace, pluginsFolder) {
            return .anotherCopy(folder: marketplace)
        }
        return ours["enabled"] as? Bool == false ? .disabled : .installed
    }

    /// Whether two paths name the same folder. The agents record the path
    /// they were given, so symbolic links are resolved on both sides; a folder
    /// that's gone is compared as it's written.
    static func sameFolder(_ one: String, _ other: String) -> Bool {
        func resolved(_ path: String) -> String {
            let real = ExecutableSearch.realPath(path)
            return real.count > 1 && real.hasSuffix("/") ? String(real.dropLast()) : real
        }
        return one == other || resolved(one) == resolved(other)
    }

    /// Whether Codex's `config.toml` trusts any of the plugin's hooks. Codex
    /// writes each as a table such as
    /// `[hooks.state."roga-hooks@roga:hooks/codex.json:stop:0:0"]`, and the
    /// quoted key is searched for on its own so the inline form counts too.
    static func codexTrustsHooks(_ configuration: String) -> Bool {
        configuration.contains("\"\(HookPlugin.pluginID):\(HookPlugin.codexHooksPath):")
    }

    /// A file URL's path, without percent encoding or a trailing slash, the way
    /// the agents get it and record it.
    static func plainPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
