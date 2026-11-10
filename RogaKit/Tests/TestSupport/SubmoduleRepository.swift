import Foundation
import GitRunner

/// A repository with a submodule, for the tests of decision 75. Each test gets
/// its own, because most of them change it.
///
/// `origin` is the submodule's own repository, with five commits by Sam Lee, a
/// minute apart, each adding a line to `lib.txt`. `parent` records it at
/// `vendor/parser` and has it checked out. Its history moves the submodule
/// three times, and ends with the fifth commit recorded and checked out:
///
///     Move parser forward again   fourth → fifth
///     Move parser back            fifth → fourth    `back`
///     Move parser forward         second → fifth    `forward`
///     Add parser                  at the second
///     First
public struct SubmoduleRepository: Sendable {
    /// Where the parent has the submodule.
    public static let path = "vendor/parser"

    /// The folder that holds both repositories.
    public let root: String
    /// The submodule's commits, oldest first, as full hashes.
    public let commits: [String]
    /// The parent's commit that moves the submodule from its second commit to
    /// its fifth.
    public let forward: String
    /// The parent's commit that moves it from its fifth commit to its fourth.
    public let back: String

    /// The submodule's own repository, which the parent clones it from.
    public var origin: String { root + "/parser-origin" }
    public var parent: String { root + "/parent" }
    /// The submodule's checkout in the parent.
    public var checkout: String { parent + "/" + Self.path }

    /// A git that may clone and fetch from a folder, which git otherwise
    /// refuses to do for a submodule. The setting goes in the environment, so
    /// that the gits that git starts get it too. Its commits are Sam Lee's,
    /// whoever the environment the tests run in says is committing.
    public static func git() async throws -> Git {
        Git(
            installation: try await TestGit.installation(),
            log: CommandLog(),
            environment: TestGit.isolatedEnvironment.merging([
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "protocol.file.allow",
                "GIT_CONFIG_VALUE_0": "always",
                "GIT_AUTHOR_NAME": "Sam Lee",
                "GIT_AUTHOR_EMAIL": "sam.lee@example.com",
                "GIT_COMMITTER_NAME": "Sam Lee",
                "GIT_COMMITTER_EMAIL": "sam.lee@example.com",
            ]) { $1 }
        )
    }

    /// Makes the repositories in a new temporary folder.
    ///
    /// Building them takes about forty git commands, which is slow when many
    /// tests do it at once on a busy machine. So they're built once for a test
    /// run, and each test gets a copy of the folder. The places that hold the
    /// folder's path are then changed to the copy's: where the parent clones
    /// the submodule from, and where the submodule fetches from. The
    /// `.gitmodules` file is left as it was committed, and still names the
    /// first folder, which nothing here reads.
    public static func make() async throws -> SubmoduleRepository {
        let template = try await built.value
        let root = try temporaryFolder() + "/repositories"
        try FileManager.default.copyItem(atPath: template.root, toPath: root)
        let copy = SubmoduleRepository(root: root, commits: template.commits, forward: template.forward, back: template.back)
        for config in [copy.parent + "/.git/config", copy.parent + "/.git/modules/" + path + "/config"] {
            let text = try String(contentsOfFile: config, encoding: .utf8)
            try text.replacing(template.root, with: root).write(toFile: config, atomically: true, encoding: .utf8)
        }
        return copy
    }

    private static let built = Task { try await build() }

    private static func build() async throws -> SubmoduleRepository {
        let root = try temporaryFolder() + "/repositories"
        let origin = root + "/parser-origin"
        let parent = root + "/parent"
        let git = try await git()

        @discardableResult
        func run(_ arguments: [String], in directory: String, at minute: Int = 0) async throws -> String {
            var command = GitCommand(arguments, in: directory)
            let date = "2026-11-03T17:\(String(format: "%02d", minute)):00+00:00"
            command.environment["GIT_AUTHOR_DATE"] = date
            command.environment["GIT_COMMITTER_DATE"] = date
            return try await git.text(command)
        }
        func start(_ repository: String) async throws {
            try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
            try await run(["init", "--quiet", "--initial-branch=main"], in: repository)
        }

        try await start(origin)
        var commits: [String] = []
        for number in 1...5 {
            let text = (1...number).map { "line \($0)\n" }.joined()
            try Data(text.utf8).write(to: URL(filePath: origin + "/lib.txt"))
            try await run(["add", "lib.txt"], in: origin)
            try await run(["commit", "--quiet", "--message=Parser commit \(number)"], in: origin, at: number)
            commits.append(try await run(["rev-parse", "HEAD"], in: origin))
        }

        try await start(parent)
        try Data("hello\n".utf8).write(to: URL(filePath: parent + "/a.txt"))
        try await run(["add", "a.txt"], in: parent)
        try await run(["commit", "--quiet", "--message=First"], in: parent, at: 10)
        try await run(["submodule", "--quiet", "add", origin, path], in: parent)
        let checkout = parent + "/" + path

        /// Checks the submodule out at one of its commits and commits that in
        /// the parent.
        func record(_ commit: Int, _ message: String, at minute: Int) async throws -> String {
            try await run(["checkout", "--quiet", "--detach", commits[commit]], in: checkout)
            try await run(["add", path], in: parent)
            try await run(["commit", "--quiet", "--message=" + message], in: parent, at: minute)
            return try await run(["rev-parse", "HEAD"], in: parent)
        }
        _ = try await record(1, "Add parser", at: 11)
        let forward = try await record(4, "Move parser forward", at: 12)
        let back = try await record(3, "Move parser back", at: 13)
        _ = try await record(4, "Move parser forward again", at: 14)
        return SubmoduleRepository(root: root, commits: commits, forward: forward, back: back)
    }

    /// A new folder, by its real path, because git reports real paths and the
    /// temporary folder is behind a symbolic link.
    private static func temporaryFolder() throws -> String {
        let folder = FileManager.default.temporaryDirectory.appending(path: "roga-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let resolved = realpath(folder.path(percentEncoded: false), nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Runs git in one of the folders, with the git that built them.
    @discardableResult
    public func run(_ arguments: String..., in folder: String) async throws -> String {
        try await Self.git().text(GitCommand(arguments, in: folder))
    }

    /// Checks the submodule out at one of its own commits, by its place in
    /// `commits`, which leaves its `HEAD` detached, as `git submodule update`
    /// does.
    public func checkOut(_ commit: Int) async throws {
        try await run("checkout", "--quiet", "--detach", commits[commit], in: checkout)
    }

    /// Makes a commit inside the submodule's checkout, on top of what's checked
    /// out, and returns its hash.
    public func commitInside(_ subject: String) async throws -> String {
        let file = URL(filePath: checkout + "/lib.txt")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try Data((text + subject + "\n").utf8).write(to: file)
        try await run("commit", "--quiet", "--all", "--message=" + subject, in: checkout)
        return try await run("rev-parse", "HEAD", in: checkout)
    }

    /// Writes a file inside the submodule's checkout.
    public func writeInside(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(filePath: checkout + "/" + path))
    }
}
