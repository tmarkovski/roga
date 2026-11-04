import Foundation
import GitRunner

/// Test repositories, built by the scripts in `Tests/Fixtures` when the tests
/// run. Each one is built once per test run and shared, so tests must not
/// change them.
public enum Fixture {
    /// The `basic` repository: three commits on main, a feature branch, and an
    /// annotated tag.
    public enum Basic {
        public static let main = "da9ff97390adfc8a4a4b4c0f0a1481c9084145d5"
        public static let feature = "b07dd8d5b4878ff9b1874af39742374879add7e1"
        public static let tag = "a29ac133f920c06cbb0d2c96475d9067ace72ca7"
        /// main's commits, newest first.
        public static let mainHistory = [
            "da9ff97390adfc8a4a4b4c0f0a1481c9084145d5",
            "ef4cfd964ac0378cb3723640730be1b46724b795",
            "ca732cfef503594e47855777e758bd0539fcecbd",
        ]
        public static let mainTree = "407153ae6640b677b6d83c08329048174e634843"
        /// The blob for `README.md`.
        public static let readme = "ef045c580cffe77c02cb1218c57e6f2c9c64928c"
    }

    /// The `history` repositories: one history, with merges, an octopus
    /// merge, a second root, commits with the same time, and dates out of
    /// order, whose commit-graph is stored in different ways. Each one is a
    /// folder inside the fixture's folder.
    public enum History: String, CaseIterable, Sendable {
        /// One commit-graph file.
        case single
        /// A split chain of three layers.
        case chain
        /// A chain whose upper layers have no corrected commit dates.
        case mixed
        /// One file that leaves out the newest commits.
        case stale
        /// One file, in a repository that uses SHA-256.
        case sha256

        /// Builds the repositories if they aren't built yet, and returns the
        /// real path of this one.
        public func repository() async throws -> String {
            try await Fixture.repository("history") + "/" + rawValue
        }
    }

    /// Builds the repository that `Tests/Fixtures/<name>.sh` describes, or
    /// returns the one already built, and returns its real path.
    public static func repository(_ name: String) async throws -> String {
        try await cache.repository(name)
    }

    static let fixturesFolder = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures")

    private static let cache = Cache()

    private actor Cache {
        private var builds: [String: Task<String, any Error>] = [:]

        func repository(_ name: String) async throws -> String {
            if let build = builds[name] { return try await build.value }
            let build = Task { try await Fixture.build(name) }
            builds[name] = build
            return try await build.value
        }
    }

    private static func build(_ name: String) async throws -> String {
        let installation = try await TestGit.installation()
        let parent = FileManager.default.temporaryDirectory.appending(path: "roga-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // git reports real paths, and the temporary folder is behind a symbolic
        // link. Foundation's resolvingSymlinksInPath() leaves out /private, so
        // it can't be used for this.
        guard let resolved = realpath(parent.path(percentEncoded: false), nil) else {
            throw FixtureError(description: "Couldn't find the real path of \(parent.path(percentEncoded: false))")
        }
        let folder = String(cString: resolved) + "/" + name
        free(resolved)

        let script = fixturesFolder.appending(path: "\(name).sh").path(percentEncoded: false)
        let gitFolder = (installation.executable as NSString).deletingLastPathComponent
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = gitFolder + ":" + (environment["PATH"] ?? "/usr/bin:/bin")

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script, folder]
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw FixtureError(description: "\(name).sh exited with status \(status): \(message)")
        }
        return folder
    }
}

struct FixtureError: Error, CustomStringConvertible {
    var description: String
}
