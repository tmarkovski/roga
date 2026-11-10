import Foundation
import GitRunner

extension AgentKind {
    /// The name of the agent's command-line tool, as someone would type it.
    public var executableName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }

    /// Where the agent's installers put its command-line tool, which Roga looks
    /// at after the folders in `PATH`. An app started from Finder doesn't get
    /// the shell's `PATH`, and even the login shell's may leave out a folder an
    /// installer only added to one shell's startup file.
    public func wellKnownPaths(home: String) -> [String] {
        switch self {
        case .claude:
            [
                home + "/.local/bin/claude",
                home + "/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ]
        case .codex:
            [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                home + "/.local/bin/codex",
                // The ChatGPT app keeps its own copy, which is often newer than
                // the one in Homebrew.
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            ]
        }
    }

    /// The oldest version Roga can use. Claude Code needs 2.1.169 for
    /// `--safe-mode`, which keeps every hook and plugin out of the runs that
    /// write commit messages. Codex needs 0.131.0, the first that runs a
    /// plugin's hooks by default and asks people to trust them.
    public var minimumVersion: AgentVersion {
        switch self {
        case .claude: AgentVersion(major: 2, minor: 1, patch: 169)
        case .codex: AgentVersion(major: 0, minor: 131, patch: 0)
        }
    }

    /// Whether the newest copy wins rather than the first one in `PATH`.
    ///
    /// Codex's server refuses old versions for new models, and the copy inside
    /// the ChatGPT app is often newer than the one someone installed, so the
    /// newest one found is the one that works. Claude Code keeps itself up to
    /// date, so the first usable one in `PATH` order wins, the way Roga finds
    /// git, and it's the same one the person's terminal runs.
    public var prefersNewest: Bool {
        switch self {
        case .claude: false
        case .codex: true
        }
    }
}

/// A copy of an agent's tool that Roga could use.
public struct FoundAgent: Sendable, Hashable {
    public var executable: String
    public var version: AgentVersion

    public init(executable: String, version: AgentVersion) {
        self.executable = executable
        self.version = version
    }
}

/// A copy of an agent's tool that Roga found and couldn't use. Settings lists
/// them, so nobody wonders why Roga runs a different copy than their terminal.
public struct SkippedAgent: Sendable, Hashable, CustomStringConvertible {
    public var kind: AgentKind
    public var executable: String

    public enum Reason: Sendable, Hashable {
        /// It didn't print a version Roga could read. The status is how it
        /// ended, or nil when it couldn't be started, and the output is what it
        /// said about it.
        case noVersion(status: ExitStatus?, errorOutput: String)
        /// It didn't print its version within the time limit, so Roga stopped it.
        case timedOut
        /// It's older than `AgentKind.minimumVersion`.
        case tooOld(AgentVersion)
    }

    public var reason: Reason

    public init(kind: AgentKind, executable: String, reason: Reason) {
        self.kind = kind
        self.executable = executable
        self.reason = reason
    }

    public var description: String {
        let path = (executable as NSString).abbreviatingWithTildeInPath
        switch reason {
        case .tooOld(let version):
            return "\(path) is \(kind.name) \(version), older than \(kind.minimumVersion)"
        case .timedOut:
            return "\(path) didn't say its version within \(AgentInstallation.probeTimeLimit.formatted(.units(allowed: [.seconds], width: .wide)))"
        case .noVersion(let status, let errorOutput):
            let said = Self.firstLine(of: errorOutput)
            let detail = said.isEmpty ? "" : ": \(said)"
            switch status {
            case nil:
                return "\(path) couldn't be started\(detail)"
            case .exited(0)?:
                return "\(path) didn't print a version Roga could read\(detail)"
            case let status?:
                return "\(path) \(status) before saying its version\(detail)"
            }
        }
    }

    /// The first line that says something, without the `dyld[123]: ` that the
    /// loader puts before its messages, since that number means nothing to
    /// anyone reading Settings.
    private static func firstLine(of text: String) -> String {
        var line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if line.hasPrefix("dyld["), let end = line.firstIndex(of: "]") {
            line = String(line[line.index(after: end)...]).trimmingPrefix(":").trimmingCharacters(in: .whitespaces)
        }
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }
}

/// The copy of an agent's tool that Roga runs, and what else it found.
public struct AgentInstallation: Sendable, Hashable {
    public var kind: AgentKind
    /// The absolute path of the program.
    public var executable: String
    public var version: AgentVersion
    /// The usable copies that weren't chosen, in the order Roga found them.
    public var others: [FoundAgent]
    /// The copies Roga couldn't use, in the order it found them.
    public var skipped: [SkippedAgent]

    public init(kind: AgentKind, executable: String, version: AgentVersion, others: [FoundAgent] = [], skipped: [SkippedAgent] = []) {
        self.kind = kind
        self.executable = executable
        self.version = version
        self.others = others
        self.skipped = skipped
    }
}

/// What looking for an agent's tool came to.
public enum AgentLookup: Sendable, Hashable {
    case found(AgentInstallation)
    /// There's no copy anywhere Roga looks, which means the agent isn't installed.
    case notFound
    /// Every copy Roga found was too old or didn't say its version.
    case unusable([SkippedAgent])
    /// The program chosen in Settings doesn't exist or can't be run.
    case configuredMissing(String)
    /// The program chosen in Settings is too old or didn't say its version.
    case configuredUnusable(SkippedAgent)
}

/// Every copy of an agent's tool that Roga found, in the order it looks, so
/// that setup and Settings can list them and say which one Roga uses by
/// itself.
public struct AgentSurvey: Sendable, Hashable {
    /// One copy, and whether Roga can use it.
    public struct Copy: Sendable, Hashable {
        public var executable: String
        /// The version, or nil for a copy that didn't print one Roga could read.
        public var version: AgentVersion?
        /// Why Roga can't use it, or nil when it can.
        public var skipped: SkippedAgent?

        public init(executable: String, version: AgentVersion?, skipped: SkippedAgent? = nil) {
            self.executable = executable
            self.version = version
            self.skipped = skipped
        }

        public var isUsable: Bool { skipped == nil && version != nil }
    }

    public var kind: AgentKind
    public var copies: [Copy]
    /// The `PATH` that was searched, before the agent's well-known places.
    public var searchPath: String
    /// The copy a terminal runs, which is the first one in `PATH`, whether or
    /// not Roga can use it, or nil when `PATH` has none.
    public var firstInPath: String?

    public init(kind: AgentKind, copies: [Copy], searchPath: String = "", firstInPath: String? = nil) {
        self.kind = kind
        self.copies = copies
        self.searchPath = searchPath
        self.firstInPath = firstInPath
    }

    /// The usable copies, in the order Roga found them.
    public var usable: [FoundAgent] {
        copies.compactMap { copy in
            copy.isUsable ? copy.version.map { FoundAgent(executable: copy.executable, version: $0) } : nil
        }
    }

    /// The copies Roga can't use, in the order it found them.
    public var skipped: [SkippedAgent] {
        copies.compactMap(\.skipped)
    }

    /// The copy Roga uses when nobody chose one: the first usable one for
    /// Claude Code and the newest for Codex, as `AgentKind.prefersNewest`
    /// explains.
    public var recommended: FoundAgent? {
        let usable = usable
        guard var chosen = usable.first else { return nil }
        if kind.prefersNewest {
            // The first of the newest, so that a tie goes to PATH order.
            for found in usable where found.version > chosen.version {
                chosen = found
            }
        }
        return chosen
    }

    /// What looking for the agent comes to when nobody chose a program.
    public var lookup: AgentLookup {
        guard !copies.isEmpty else { return .notFound }
        guard let chosen = recommended else { return .unusable(skipped) }
        return .found(AgentInstallation(
            kind: kind,
            executable: chosen.executable,
            version: chosen.version,
            others: usable.filter { $0.executable != chosen.executable },
            skipped: skipped
        ))
    }
}

extension AgentInstallation {
    /// How long a copy has to print its version. A tool that needs longer is
    /// probably waiting for something, such as a login prompt it can't show.
    public static let probeTimeLimit = Duration.seconds(5)

    /// Finds an agent's tool, in this order (decision 41):
    ///
    /// 1. the program chosen in Settings, which is used or reported, and never
    ///    passed over for another
    /// 2. the folders in `searchPath`, in order
    /// 3. `wellKnown`, or the kind's `wellKnownPaths` when it's nil
    ///
    /// Each copy found is asked for its version, all at once since each takes a
    /// moment to start. For Claude Code the first usable copy wins and for
    /// Codex the newest, as `AgentKind.prefersNewest` explains.
    ///
    /// The probes run at utility priority with a 5 s limit each: Roga looks
    /// when it launches, before anyone asks for an agent, and a person may be
    /// waiting by the time they finish.
    @concurrent
    public static func locate(
        _ kind: AgentKind,
        configuredPath: String?,
        searchPath: String,
        programs: Programs,
        home: String = NSHomeDirectory(),
        wellKnown: [String]? = nil
    ) async -> AgentLookup {
        await locate(
            kind,
            configuredPath: configuredPath,
            searchPath: searchPath,
            programs: programs,
            home: home,
            wellKnown: wellKnown,
            timeLimit: probeTimeLimit
        )
    }

    /// `locate`, with a time limit that tests can shorten.
    @concurrent
    static func locate(
        _ kind: AgentKind,
        configuredPath: String?,
        searchPath: String,
        programs: Programs,
        home: String,
        wellKnown: [String]?,
        timeLimit: Duration
    ) async -> AgentLookup {
        if let configuredPath, !configuredPath.isEmpty {
            guard ExecutableSearch.isExecutableFile(configuredPath) else {
                return .configuredMissing(configuredPath)
            }
            switch await probe(kind, configuredPath, programs: programs, timeLimit: timeLimit) {
            case .usable(let version):
                return .found(AgentInstallation(kind: kind, executable: configuredPath, version: version))
            case .skipped(let skipped):
                return .configuredUnusable(skipped)
            }
        }

        return await survey(kind, searchPath: searchPath, programs: programs, home: home, wellKnown: wellKnown, timeLimit: timeLimit).lookup
    }

    /// Finds every copy of an agent's tool where `locate` looks, in the same
    /// order, and asks each for its version, all at once since each takes a
    /// moment to start.
    @concurrent
    public static func survey(
        _ kind: AgentKind,
        searchPath: String,
        programs: Programs,
        home: String = NSHomeDirectory(),
        wellKnown: [String]? = nil
    ) async -> AgentSurvey {
        await survey(kind, searchPath: searchPath, programs: programs, home: home, wellKnown: wellKnown, timeLimit: probeTimeLimit)
    }

    /// `survey`, with a time limit that tests can shorten.
    @concurrent
    static func survey(
        _ kind: AgentKind,
        searchPath: String,
        programs: Programs,
        home: String,
        wellKnown: [String]?,
        timeLimit: Duration
    ) async -> AgentSurvey {
        let candidates = ExecutableSearch.candidates(
            named: [kind.executableName],
            searchPath: searchPath,
            wellKnown: wellKnown ?? kind.wellKnownPaths(home: home)
        )
        let firstInPath = ExecutableSearch.candidates(named: [kind.executableName], searchPath: searchPath, wellKnown: []).first
        guard !candidates.isEmpty else { return AgentSurvey(kind: kind, copies: [], searchPath: searchPath, firstInPath: firstInPath) }

        let results = await withTaskGroup(of: (Int, Probe).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    (index, await probe(kind, candidate, programs: programs, timeLimit: timeLimit))
                }
            }
            var results = [Probe?](repeating: nil, count: candidates.count)
            for await (index, result) in group {
                results[index] = result
            }
            return results.compactMap { $0 }
        }

        let copies = zip(candidates, results).map { candidate, result in
            switch result {
            case .usable(let version):
                return AgentSurvey.Copy(executable: candidate, version: version)
            case .skipped(let skipped):
                let version: AgentVersion? = if case .tooOld(let version) = skipped.reason { version } else { nil }
                return AgentSurvey.Copy(executable: candidate, version: version, skipped: skipped)
            }
        }
        return AgentSurvey(kind: kind, copies: copies, searchPath: searchPath, firstInPath: firstInPath)
    }

    /// What asking one copy for its version came to.
    enum Probe: Sendable {
        case usable(AgentVersion)
        case skipped(SkippedAgent)
    }

    /// Runs `<executable> --version` and reads the version, or says why it
    /// can't be used.
    @concurrent
    static func probe(
        _ kind: AgentKind,
        _ executable: String,
        programs: Programs,
        timeLimit: Duration
    ) async -> Probe {
        var command = ProgramCommand(executable, ["--version"])
        command.priority = .utility
        command.timeout = timeLimit
        command.outputLimit = 64 << 10
        func skipped(_ reason: SkippedAgent.Reason) -> Probe {
            .skipped(SkippedAgent(kind: kind, executable: executable, reason: reason))
        }
        let result: ProgramResult
        do {
            result = try await programs.run(command)
        } catch ProgramError.timedOut {
            return skipped(.timedOut)
        } catch let error as ProgramError {
            // Only a program that couldn't start has no status. One that
            // printed too much was stopped by Roga partway.
            let started = if case .couldNotStart = error { false } else { true }
            return skipped(.noVersion(status: started ? .unknown : nil, errorOutput: error.description))
        } catch {
            // The lookup was cancelled, so nobody will read this.
            return skipped(.noVersion(status: nil, errorOutput: ""))
        }
        guard result.succeeded, let version = AgentVersion(versionOutput: result.text) else {
            let errorOutput = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let said = errorOutput.isEmpty ? result.text.trimmingCharacters(in: .whitespacesAndNewlines) : errorOutput
            return skipped(.noVersion(status: result.status, errorOutput: said))
        }
        guard version >= kind.minimumVersion else { return skipped(.tooOld(version)) }
        return .usable(version)
    }
}
