import Foundation
import GitCore
import GitRunner
import Synchronization
import TestSupport
import Testing
@testable import RepositoryEngine

@Suite(.timeLimit(.minutes(1)))
struct CloningTests {
    let folder: String

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "roga-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let resolved = try #require(realpath(temporary.path(percentEncoded: false), nil))
        defer { free(resolved) }
        folder = String(cString: resolved)
    }

    // MARK: The request

    @Test(arguments: [
        ("https://github.com/torvalds/linux", "linux"),
        ("https://github.com/torvalds/linux.git", "linux"),
        ("https://github.com/torvalds/linux/", "linux"),
        ("git@github.com:torvalds/linux.git", "linux"),
        ("git@example.com:linux.git", "linux"),
        ("ssh://git@example.com:2222/team/api.git/", "api"),
        ("/Users/me/git/api/.git", "api"),
        ("  https://github.com/git/git  ", "git"),
        ("https://github.com", ""),
        ("", ""),
    ])
    func namesTheFolderAfterTheURL(url: String, name: String) {
        #expect(CloneRequest.name(fromURL: url) == name)
    }

    @Test func clonesSubmodulesWhenAsked() {
        var request = CloneRequest(url: "https://github.com/git/git", folder: "/Users/me/git", name: "git")
        #expect(request.arguments == ["clone", "--progress", "--recurse-submodules", "--end-of-options", "https://github.com/git/git", "/Users/me/git/git"])
        request.recursesSubmodules = false
        #expect(request.arguments == ["clone", "--progress", "--end-of-options", "https://github.com/git/git", "/Users/me/git/git"])
    }

    @Test func saysWhatsInTheWay() throws {
        try FileManager.default.createDirectory(atPath: folder + "/taken", withIntermediateDirectories: true)
        func problem(url: String = "https://example.com/a/b", name: String) -> CloneRequest.Problem? {
            CloneRequest(url: url, folder: folder, name: name).problem
        }
        #expect(problem(name: "free") == nil)
        #expect(problem(url: "  ", name: "free") == .noURL)
        #expect(problem(name: "") == .noName)
        #expect(problem(name: "a/b") == .nameIsNotAFolder)
        #expect(problem(name: "..") == .nameIsNotAFolder)
        #expect(problem(name: "taken") == .destinationExists)
    }

    // MARK: Reading progress

    @Test func readsHowFarAlongItIs() {
        var reader = CloneProgressReader(destination: "/Users/me/git/api")
        #expect(reader.read(Array("Cloning into '/Users/me/git/api'...\n".utf8)) == nil)
        #expect(reader.read(Array("remote: Enumerating objects: 1234, done.        \n".utf8)) == CloneProgress(step: "enumerating objects"))
        #expect(reader.read(Array("remote: Counting objects:  50% (1/2)        \r".utf8)) == CloneProgress(step: "counting objects", percent: 50))
        // A chunk can end partway through an update, which waits for the rest.
        #expect(reader.read(Array("Receiving objects:  4".utf8)) == nil)
        #expect(reader.read(Array("2% (520/1234), 1.20 MiB | 2.30 MiB/s\rReceiving".utf8)) == CloneProgress(step: "receiving objects", percent: 42))
        #expect(reader.read(Array(" objects:  42% (521/1234), 1.21 MiB | 2.30 MiB/s\r".utf8)) == nil)
        #expect(reader.read(Array("Resolving deltas:   7% (8/100)\r".utf8)) == CloneProgress(step: "resolving deltas", percent: 7))
        // What isn't progress leaves it as it was.
        #expect(reader.read(Array("warning: redirecting to https://example.com/api.git/\n".utf8)) == nil)
        #expect(reader.read(Array("Submodule 'lib' (https://example.com/lib.git) registered for path 'vendor/lib'\n".utf8)) == nil)
        #expect(reader.read(Array("Cloning into '/Users/me/git/api/vendor/lib'...\n".utf8)) == CloneProgress(submodule: "vendor/lib"))
        #expect(reader.read(Array("Receiving objects: 100% (9/9), done.\n".utf8)) == CloneProgress(step: "receiving objects", percent: 100, submodule: "vendor/lib"))
    }

    @Test func leavesProgressOutOfWhatGitSaid() {
        let said = """
            Cloning into '/Users/me/git/api'...
            remote: Enumerating objects: 3, done.        \nremote: Counting objects:  33% (1/3)        \rremote: Counting objects: 100% (3/3), done.
            remote: Repository not found.
            remote:
            fatal: repository 'https://example.com/api/' not found

            """
        #expect(CloneProgressReader.messages(in: said) == """
            Cloning into '/Users/me/git/api'...
            remote: Repository not found.
            fatal: repository 'https://example.com/api/' not found
            """)
    }

    // MARK: Running git

    @Test func clonesARepository() async throws {
        let git = try await TestGit.make()
        let source = try await Fixture.repository("basic")
        let request = CloneRequest(url: "file://" + source, folder: folder, name: "basic")
        let seen = Mutex<[CloneProgress]>([])
        try await Cloning.run(request, git: git) { progress in seen.withLock { $0.append(progress) } }
        let head = try await git.text(GitCommand("rev-parse", "HEAD", in: request.destination))
        #expect(head == Fixture.Basic.main)
        #expect(seen.withLock { $0 }.contains { $0.step == "receiving objects" && $0.percent == 100 })
    }

    @Test func saysWhatGitSaidWhenItRefuses() async throws {
        let git = try await TestGit.make()
        let request = CloneRequest(url: folder + "/nowhere", folder: folder, name: "nowhere-clone")
        let error = await #expect(throws: GitError.self) {
            try await Cloning.run(request, git: git) { _ in }
        }
        guard case .failed(let command, _, let said) = error else {
            Issue.record("Expected GitError.failed, got \(String(describing: error))")
            return
        }
        #expect(command.arguments == request.arguments)
        #expect(said.contains("does not exist"))
        #expect(!FileManager.default.fileExists(atPath: request.destination))
    }

    @Test func stoppingItDeletesWhatItMade() async throws {
        // The ext transport runs a command in place of a server, here one that
        // never answers, so the clone waits after making its folder.
        let git = Git(
            installation: try await TestGit.installation(),
            environment: TestGit.isolatedEnvironment.merging(["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.ext.allow", "GIT_CONFIG_VALUE_0": "always"]) { $1 }
        )
        let request = CloneRequest(url: "ext::sleep 30", folder: folder, name: "slow", recursesSubmodules: false)
        let clone = Task { try await Cloning.run(request, git: git) { _ in } }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: request.destination), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: request.destination))
        clone.cancel()
        await #expect(throws: CancellationError.self) { try await clone.value }
        #expect(!FileManager.default.fileExists(atPath: request.destination))
    }
}
