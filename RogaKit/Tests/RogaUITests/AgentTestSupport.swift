import AgentEngine
import Foundation
import GitRunner
import TestSupport
@testable import RogaUI

/// Fake `claude` and `codex` programs and the folders they live in, for the
/// tests of agents in the app. No test runs a real agent, or reads or writes
/// the user's own agent settings or Roga's own support folder.
enum AgentTestSupport {
    /// A new, empty folder at its real path. Its name is short, because a
    /// socket's path has to fit in 104 bytes.
    static func folder() throws -> String {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let folder = temporary.appending(path: "ra-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return path(folder)
    }

    /// Writes an executable shell script called `name` in `folder` and returns
    /// its path. The scripts run with only `folder` in their `PATH`, so they
    /// name every other program by its full path.
    @discardableResult
    static func script(_ body: String, named name: String, in folder: String) throws -> String {
        let file = folder + "/" + name
        try ("#!/bin/sh\n" + body + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)
        return file
    }

    /// A fake Claude Code: it says its version, records every other run in
    /// `log`, lists no plugins, and lists the sessions in `sessions`, a file of
    /// `claude agents --json` output, after waiting `delay` seconds.
    @discardableResult
    static func claude(in folder: String, log: String, sessions: String? = nil, delay: Double = 0, body: String = "") throws -> String {
        try script("""
            if [ "$1" = "--version" ]; then echo '2.1.290 (Claude Code)'; exit 0; fi
            \(recording(to: log))
            \(body)
            if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then echo '[]'; exit 0; fi
            if [ "$1" = "agents" ]; then /bin/sleep \(delay); /bin/cat '\(sessions ?? "/dev/null")'; exit 0; fi
            exit 0
            """, named: "claude", in: folder)
    }

    /// A fake Codex, which says its version and has no plugins.
    @discardableResult
    static func codex(in folder: String, log: String) throws -> String {
        try script("""
            if [ "$1" = "--version" ]; then echo 'codex-cli 0.166.0'; exit 0; fi
            \(recording(to: log))
            if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then echo '{"installed":[]}'; exit 0; fi
            exit 0
            """, named: "codex", in: folder)
    }

    /// Lines that record a run in `log`, each argument in brackets.
    static func recording(to log: String) -> String {
        """
        for argument in "$@"; do printf '[%s]' "$argument" >> '\(log)'; done
        printf '\\n' >> '\(log)'
        """
    }

    /// The runs a recording script logged, one array of arguments per run.
    static func runs(in log: String) -> [[String]] {
        guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { line in
            line.dropFirst().dropLast().components(separatedBy: "][")
        }
    }

    /// A git whose login shell's `PATH` is only `folder`, so that the agents
    /// found are the fake ones there.
    static func git(searchPath folder: String) async throws -> Git {
        var installation = try await TestGit.installation()
        installation.searchPath = folder
        return Git(installation: installation, environment: TestGit.isolatedEnvironment)
    }

    /// Defaults of their own, kept in a temporary folder rather than in the
    /// Preferences folder: a suite named by an absolute path is a file there.
    static func defaults() -> (UserDefaults, name: String) {
        let folder = (try? folder()) ?? NSTemporaryDirectory()
        let name = folder + "/defaults"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// Removes a test's defaults.
    static func remove(_ defaults: UserDefaults, named name: String) {
        defaults.removePersistentDomain(forName: name)
    }

    /// A provider that finds nothing but the fake agents in `bin`, keeps its
    /// files in `support`, and has a Codex folder of its own.
    @MainActor
    static func provider(support: String, helperPath: String? = nil, defaults: UserDefaults, codexHome: String) -> AgentProvider {
        AgentProvider(
            supportFolder: URL(filePath: support, directoryHint: .isDirectory),
            helperPath: helperPath,
            defaults: defaults,
            codexHome: codexHome,
            wellKnown: [:]
        )
    }

    /// Waits until `condition` holds, for at most `limit`, and says whether it
    /// came to hold.
    @MainActor
    static func eventually(within limit: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    static func path(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
