import Foundation
@testable import GitRunner

/// A new, empty temporary folder, at its real path. The temporary folder is
/// behind a symbolic link, and git and `pwd` report real paths.
func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "yaga-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return URL(filePath: GitInstallation.realPath(folder.path(percentEncoded: false)), directoryHint: .isDirectory)
}

extension URL {
    /// The path without percent encoding or a trailing slash.
    var plainPath: String {
        let path = path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// Writes an executable shell script and returns its path.
@discardableResult
func makeScript(_ body: String, named name: String = "git", in folder: URL) throws -> String {
    let url = folder.appending(path: name)
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    return url.plainPath
}

/// A `Git` whose "git" is a script, for testing what happens around git
/// rather than git itself.
func scriptedGit(_ body: String, log: CommandLog = CommandLog()) throws -> Git {
    let executable = try makeScript(body, in: try makeTemporaryFolder())
    let installation = GitInstallation(
        executable: executable,
        version: .minimumSupported,
        searchPath: "/usr/bin:/bin:/usr/sbin:/sbin"
    )
    return Git(installation: installation, log: log)
}

/// Waits until `condition` is true, for up to `timeout`.
func eventually(within timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

extension ChildProcess {
    /// Reads standard output to the end.
    func readAll() async throws -> [UInt8] {
        var bytes: [UInt8] = []
        while let chunk = try await output.next() {
            bytes.append(contentsOf: chunk)
        }
        return bytes
    }
}

let shellEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

/// Swift Testing has an `ExitStatus` of its own, for exit tests.
typealias ExitStatus = GitRunner.ExitStatus
