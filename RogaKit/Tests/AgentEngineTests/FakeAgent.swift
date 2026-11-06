import Foundation
import GitRunner

/// Fake `claude` and `codex` programs for the tests: shell scripts that print a
/// version, record how they were run, fail, hang or crash. No test runs a real
/// agent or touches the user's own agent settings.
enum FakeAgent {
    /// A new, empty temporary folder, at its real path, because the temporary
    /// folder is behind a symbolic link.
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "roga-agent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return URL(filePath: ExecutableSearch.realPath(folder.path(percentEncoded: false)), directoryHint: .isDirectory)
    }

    /// Writes an executable shell script called `name` in `folder` and returns
    /// its path.
    @discardableResult
    static func script(_ body: String, named name: String, in folder: URL) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return path(url)
    }

    /// A folder holding a program called `name` that prints `version` the way
    /// the real tool does, and returns the folder's path.
    static func folder(with name: String, printing version: String) throws -> String {
        let folder = try folder()
        try script("echo '\(version)'", named: name, in: folder)
        return path(folder)
    }

    /// A script that records each run as one line in `log`, each argument in
    /// brackets, and then runs `then`.
    ///
    /// The line goes in one write, so that two runs at once that share a log
    /// can't mix their arguments into one line.
    static func recording(to log: String, then body: String = "exit 0") -> String {
        """
        line=''; for argument in "$@"; do line="$line[$argument]"; done
        printf '%s\\n' "$line" >> '\(log)'
        \(body)
        """
    }

    /// The runs a recording script logged, one array of arguments per run.
    static func runs(in log: String) -> [[String]] {
        guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { line in
            line.dropFirst().dropLast().components(separatedBy: "][")
        }
    }

    static func path(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static let programs = Programs(searchPath: "/usr/bin:/bin:/usr/sbin:/sbin")
}
