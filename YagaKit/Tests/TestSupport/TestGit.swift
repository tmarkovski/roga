import Foundation
import GitRunner

/// The git that the tests run.
public enum TestGit {
    /// Variables that keep the user's and the system's configuration out of
    /// the tests, and make git's messages English.
    public static let isolatedEnvironment = [
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "LC_ALL": "C",
    ]

    /// The first supported git on the `PATH` the tests run with. CI puts the
    /// git it's testing first.
    public static func installation() async throws -> GitInstallation {
        try await located.value
    }

    /// A `Git` for the tests, which keeps the user's configuration out.
    public static func make(log: CommandLog = CommandLog()) async throws -> Git {
        Git(installation: try await installation(), log: log, environment: isolatedEnvironment)
    }

    private static let located = Task { () throws -> GitInstallation in
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return try await GitInstallation.locate(configuredPath: nil, searchPath: path)
    }
}
