import Darwin
import Foundation
import Synchronization

/// The git that Roga runs, and the `PATH` that git gets for the programs it
/// starts itself, such as credential helpers and `ssh`.
public struct GitInstallation: Sendable, Hashable {
    /// The absolute path of the git binary.
    public var executable: String
    public var version: GitVersion
    /// The `PATH` in git's environment.
    public var searchPath: String
    /// The gits that Roga found before this one and passed over, because they
    /// were older than the minimum or didn't report a version. Settings shows
    /// them, so nobody wonders why Roga runs a different git than their
    /// terminal.
    public var skipped: [SkippedGit]

    public init(executable: String, version: GitVersion, searchPath: String, skipped: [SkippedGit] = []) {
        self.executable = executable
        self.version = version
        self.searchPath = searchPath
        self.skipped = skipped
    }

    /// A git that Roga found but didn't use.
    public struct SkippedGit: Sendable, Hashable, CustomStringConvertible {
        public var executable: String
        /// The version, or nil when running `git version` failed.
        public var version: GitVersion?

        public init(executable: String, version: GitVersion?) {
            self.executable = executable
            self.version = version
        }

        public var description: String {
            if let version {
                "\(executable) is git \(version), which is older than \(GitVersion.minimumSupported)"
            } else {
                "\(executable) didn't report its version"
            }
        }
    }

    /// The folders Homebrew installs into, on Apple silicon and on Intel Macs.
    public static let homebrewDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Apple's git, which is a stub that asks to install the Command Line
    /// Tools when neither they nor Xcode are installed.
    public static let developerToolsGit = "/usr/bin/git"

    /// Finds git the way Roga does at launch, reading the `PATH` from the
    /// user's login shell.
    ///
    /// - Parameter configuredPath: The git chosen in Settings, if any. When
    ///   it's set, Roga uses it or nothing.
    @concurrent
    public static func locate(configuredPath: String? = nil) async throws(GitInstallationError) -> GitInstallation {
        let inherited = ProcessInfo.processInfo.environment
        let searchPath = await LoginShellPath.read() ?? inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return try await locate(configuredPath: configuredPath, searchPath: searchPath)
    }

    /// Finds git in this order, and uses the first one that's at least the
    /// minimum version (decision 8):
    ///
    /// 1. the git chosen in Settings, which is used or reported, and never
    ///    passed over for another
    /// 2. the folders in `searchPath`, in order
    /// 3. `wellKnownDirectories`, which are Homebrew's
    /// 4. Apple's git
    ///
    /// Apple's git is only run when `developerToolsInstalled` says the
    /// developer tools are there, wherever it comes up in the search, because
    /// otherwise running it opens a dialog that offers to install them
    /// (decision 3).
    public static func locate(
        configuredPath: String?,
        searchPath: String,
        wellKnownDirectories: [String] = homebrewDirectories,
        developerToolsGit: String = developerToolsGit,
        developerToolsInstalled: @escaping @Sendable () async -> Bool = { await developerToolsAreInstalled() },
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws(GitInstallationError) -> GitInstallation {
        let environment = Git.environment(inheriting: inheritedEnvironment, searchPath: searchPath)

        if let configuredPath {
            guard isExecutableFile(configuredPath) else {
                throw .configuredGitMissing(configuredPath)
            }
            let version = await readVersion(of: configuredPath, environment: environment)
            guard let version, version.isSupported else {
                throw .configuredGitUnsupported(SkippedGit(executable: configuredPath, version: version))
            }
            return GitInstallation(executable: configuredPath, version: version, searchPath: searchPath)
        }

        let wellKnown = (wellKnownDirectories + [(developerToolsGit as NSString).deletingLastPathComponent])
            .map { ($0 as NSString).appendingPathComponent("git") }
        // Compare real paths, so that Apple's git is recognized however a
        // folder in the search path leads to it.
        let resolvedDeveloperToolsGit = realPath(developerToolsGit)
        var skipped: [SkippedGit] = []
        var developerToolsMissing = false
        var checkedDeveloperTools: Bool?

        for candidate in ExecutableSearch.candidates(named: ["git"], searchPath: searchPath, wellKnown: wellKnown) {
            if realPath(candidate) == resolvedDeveloperToolsGit {
                if checkedDeveloperTools == nil {
                    checkedDeveloperTools = await developerToolsInstalled()
                }
                guard checkedDeveloperTools == true else {
                    developerToolsMissing = true
                    continue
                }
            }

            let version = await readVersion(of: candidate, environment: environment)
            if let version, version.isSupported {
                return GitInstallation(executable: candidate, version: version, searchPath: searchPath, skipped: skipped)
            }
            skipped.append(SkippedGit(executable: candidate, version: version))
        }

        if skipped.isEmpty {
            throw .notFound(developerToolsMissing: developerToolsMissing)
        }
        throw .unsupported(skipped, developerToolsMissing: developerToolsMissing)
    }

    /// Whether `xcode-select -p` finds Xcode or the Command Line Tools.
    public static func developerToolsAreInstalled() async -> Bool {
        let result = await ChildProcess.run(
            "/usr/bin/xcode-select",
            arguments: ["-p"],
            environment: ProcessInfo.processInfo.environment,
            timeout: .seconds(5)
        )
        return result?.status == .exited(0)
    }

    static func readVersion(of executable: String, environment: [String: String]) async -> GitVersion? {
        guard let result = await ChildProcess.run(
            executable,
            arguments: ["version"],
            environment: environment,
            timeout: .seconds(5)
        ), result.status == .exited(0) else { return nil }
        return GitVersion(versionOutput: String(decoding: result.output, as: UTF8.self))
    }

    static func isExecutableFile(_ path: String) -> Bool {
        ExecutableSearch.isExecutableFile(path)
    }

    static func realPath(_ path: String) -> String {
        ExecutableSearch.realPath(path)
    }
}

/// Why Roga can't use any git.
public enum GitInstallationError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Roga found no git. `developerToolsMissing` is true when Apple's git was
    /// passed over because neither Xcode nor the Command Line Tools are
    /// installed.
    case notFound(developerToolsMissing: Bool)
    /// Every git Roga found is older than the minimum or didn't report its
    /// version.
    case unsupported([GitInstallation.SkippedGit], developerToolsMissing: Bool)
    /// The git chosen in Settings doesn't exist or can't be run.
    case configuredGitMissing(String)
    /// The git chosen in Settings is older than the minimum or didn't report
    /// its version.
    case configuredGitUnsupported(GitInstallation.SkippedGit)

    public var description: String {
        switch self {
        case .notFound(let developerToolsMissing):
            developerToolsMissing
                ? "Roga couldn't find git. Apple's git needs the Command Line Tools, which aren't installed."
                : "Roga couldn't find git."
        case .unsupported(let skipped, _):
            "Roga needs git \(GitVersion.minimumSupported) or later. "
                + skipped.map(\.description).joined(separator: ". ") + "."
        case .configuredGitMissing(let path):
            "The git chosen in Settings, \(path), doesn't exist or can't be run."
        case .configuredGitUnsupported(let skipped):
            "The git chosen in Settings can't be used: \(skipped)."
        }
    }
}

extension ChildProcess {
    /// Runs a program to the end and returns how it exited and what it wrote
    /// to standard output. Returns nil when it couldn't be started or took
    /// longer than `timeout`, in which case it's stopped.
    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        limit: Int = 1 << 20
    ) async -> (status: ExitStatus, output: [UInt8])? {
        guard let process = try? spawn(executable: executable, arguments: arguments, environment: environment) else {
            return nil
        }
        let timedOut = Atomic(false)
        let timer = Task {
            try await Task.sleep(for: timeout)
            timedOut.store(true, ordering: .sequentiallyConsistent)
            process.terminate(grace: .milliseconds(500))
            process.output.close()
        }
        defer { timer.cancel() }

        var output: [UInt8] = []
        while let chunk = try? await process.output.next() {
            output.append(contentsOf: chunk)
            if output.count > limit {
                process.terminate()
                process.output.close()
                return nil
            }
        }
        let status = await process.exitStatus()
        if timedOut.load(ordering: .sequentiallyConsistent) { return nil }
        return (status, output)
    }
}
