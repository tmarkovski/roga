import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Listing the keys on a Mac that can sign commits, with keys the tests make
/// in a home folder of their own, and signing a commit with what the list
/// would write (decision 106).
@Suite(.timeLimit(.minutes(1)))
struct SigningKeysTests {
    /// A folder with a short path, since an agent's socket path can't be
    /// longer than 104 bytes.
    func makeShortFolder() throws -> String {
        var template = Array("/tmp/rg.XXXXXX".utf8CString)
        let made = try #require(template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) })
        return String(cString: made)
    }

    @discardableResult
    func run(_ program: String, _ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: program)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(
            process.terminationStatus == 0,
            "\(program) \(arguments) exited with \(process.terminationStatus): \(String(decoding: errorData, as: UTF8.self))"
        )
        return String(decoding: data, as: UTF8.self)
    }

    func keygen(_ path: String, comment: String) throws {
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", path])
    }

    /// Programs that see no agent, unless one is given.
    func programs(_ environment: [String: String] = ["SSH_AUTH_SOCK": "/nonexistent"]) -> Programs {
        Programs(searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", environment: environment)
    }

    /// A home folder with `.ssh` in it.
    func makeHome() throws -> (home: String, ssh: String) {
        let home = try makeTemporaryFolder()
        let ssh = home + "/.ssh"
        try FileManager.default.createDirectory(atPath: ssh, withIntermediateDirectories: true)
        return (home, ssh)
    }

    // MARK: SSH

    @Test func listsTheKeysInSSHWhosePrivateKeyIsBesideThem() async throws {
        let (home, ssh) = try makeHome()
        try keygen(ssh + "/id_ed25519", comment: "sam@rivera.dev")
        try keygen(ssh + "/work", comment: "work laptop")
        // A public key without its private key can't sign.
        try keygen(ssh + "/someone", comment: "someone else")
        try FileManager.default.removeItem(atPath: ssh + "/someone")

        let listing = await SigningKeys.list(.ssh, git: try await TestGit.make(), programs: programs(), in: home, home: home)
        #expect(listing.keys.map(\.value) == ["~/.ssh/id_ed25519.pub", "~/.ssh/work.pub"])
        #expect(listing.keys[0].details == ["ED25519", "sam@rivera.dev"])
        #expect(listing.keys[0].emails == ["sam@rivera.dev"])
        let printed = try run("/usr/bin/ssh-keygen", ["-l", "-f", ssh + "/id_ed25519.pub"])
        #expect(printed.split(separator: " ")[1] == Substring(listing.keys[0].fingerprint))
        #expect(listing.emptyReason == nil)
    }

    @Test func saysWhyThereAreNoSSHKeys() async throws {
        let (home, _) = try makeHome()
        let listing = await SigningKeys.list(.ssh, git: try await TestGit.make(), programs: programs(), in: home, home: home)
        #expect(listing.keys.isEmpty)
        #expect(listing.emptyReason?.hasPrefix("No keys in ~/.ssh or the agent.") == true)
    }

    @Test func gitSignsWithTheFileItWrites() async throws {
        let (home, ssh) = try makeHome()
        try keygen(ssh + "/id_ed25519", comment: "t@example.com")
        let repository = home + "/work"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", in: repository)
        let git = try await TestGit.make()
        let key = try #require(await SigningKeys.list(.ssh, git: git, programs: programs(), in: repository, home: home).keys.first)

        // git reads `~` in the path as the home folder.
        let signing = Git(installation: git.installation, environment: TestGit.isolatedEnvironment.merging(["HOME": home]) { $1 })
        let settings = ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "gpg.format=ssh", "-c", "user.signingkey=\(key.value)", "-c", "commit.gpgsign=true"]
        _ = try await signing.run(GitCommand(settings + ["commit", "--quiet", "--allow-empty", "-m", "Signed"], in: repository))
        #expect(try await runGit("cat-file", "commit", "HEAD", in: repository).contains("gpgsig -----BEGIN SSH SIGNATURE-----"))
    }

    @Test func listsAnAgentsKeysAndSignsWithOneThatsOnlyThere() async throws {
        let (home, ssh) = try makeHome()
        let folder = try makeShortFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try keygen(ssh + "/id_ed25519", comment: "file key")
        // A key that's only in the agent, and one whose file has only its
        // public half.
        try keygen(folder + "/agent", comment: "agent@example.com")
        try keygen(ssh + "/halved", comment: "halved key")
        let socket = folder + "/agent.sock"
        let started = try run("/usr/bin/ssh-agent", ["-s", "-a", socket])
        let pid = try #require(started.firstMatch(of: /SSH_AGENT_PID=(\d+)/).flatMap { Int32($0.1) })
        defer { kill(pid, SIGTERM) }
        try run("/usr/bin/ssh-add", ["-q", folder + "/agent", ssh + "/halved"], environment: ["SSH_AUTH_SOCK": socket])
        try FileManager.default.removeItem(atPath: ssh + "/halved")

        let git = try await TestGit.make()
        let keys = await SigningKeys.list(.ssh, git: git, programs: programs(["SSH_AUTH_SOCK": socket]), in: home, home: home).keys
        #expect(keys.map(\.title) == ["~/.ssh/halved.pub", "~/.ssh/id_ed25519.pub", "agent@example.com"])
        let agentKey = try #require(keys.last)
        #expect(agentKey.value.hasPrefix("key::ssh-ed25519 AAAA"))
        #expect(agentKey.details == ["ED25519", "in the agent"])

        let repository = home + "/work"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", in: repository)
        let signing = Git(installation: git.installation, environment: TestGit.isolatedEnvironment.merging(["HOME": home, "SSH_AUTH_SOCK": socket]) { $1 })
        let settings = ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "gpg.format=ssh", "-c", "user.signingkey=\(agentKey.value)", "-c", "commit.gpgsign=true"]
        _ = try await signing.run(GitCommand(settings + ["commit", "--quiet", "--allow-empty", "-m", "Signed"], in: repository))
        #expect(try await runGit("cat-file", "commit", "HEAD", in: repository).contains("gpgsig -----BEGIN SSH SIGNATURE-----"))
    }

    @Test func putsTheKeysThatNameTheEmailFirst() {
        func key(_ value: String, _ emails: [String]) -> SigningKey {
            SigningKey(value: value, title: value, details: [], fingerprint: value, emails: emails)
        }
        let keys = [key("a", []), key("b", ["Sam@Rivera.dev"]), key("c", ["other@example.com"])]
        #expect(SigningKeys.ordered(keys, for: "sam@rivera.dev").map(\.value) == ["b", "a", "c"])
        #expect(SigningKeys.ordered(keys, for: nil).map(\.value) == ["a", "b", "c"])
    }

    // MARK: OpenPGP

    static let gpg = ["/opt/homebrew/bin/gpg", "/usr/local/bin/gpg", "/usr/local/MacGPG2/bin/gpg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(.enabled(if: gpg != nil, "gpg isn't installed"))
    func listsTheOpenPGPKeysThatCanSign() async throws {
        let gpg = try #require(Self.gpg)
        let gnupgHome = try makeShortFolder()
        defer {
            _ = try? run((gpg as NSString).deletingLastPathComponent + "/gpgconf", ["--kill", "gpg-agent"], environment: ["GNUPGHOME": gnupgHome])
            try? FileManager.default.removeItem(atPath: gnupgHome)
        }
        let environment = ["GNUPGHOME": gnupgHome]
        try run(gpg, ["--batch", "--passphrase", "", "--quick-gen-key", "Sam Rivera <sam@rivera.dev>", "ed25519", "sign", "never"], environment: environment)
        // A key that only certifies can't sign.
        try run(gpg, ["--batch", "--passphrase", "", "--quick-gen-key", "Certifies <cert@example.com>", "ed25519", "cert", "never"], environment: environment)
        let home = try makeTemporaryFolder()

        let git = try await TestGit.make()
        let listing = await SigningKeys.list(.openPGP, git: git, programs: programs(environment), in: home, home: home)
        let key = try #require(listing.keys.first)
        #expect(listing.keys.count == 1)
        #expect(key.title == "Sam Rivera <sam@rivera.dev>")
        #expect(key.value.count == 40)
        #expect(key.details.first == "ED25519")
        #expect(key.emails == ["sam@rivera.dev"])
    }

    @Test func saysWhenItCantFindGPG() async throws {
        let home = try makeTemporaryFolder()
        let git = Git(installation: try await TestGit.installation(), environment: TestGit.isolatedEnvironment.merging(["GIT_CONFIG_PARAMETERS": "'gpg.program'='/nonexistent/gpg'"]) { $1 })
        let listing = await SigningKeys.list(.openPGP, git: git, programs: programs(), in: home, home: home)
        #expect(listing.keys.isEmpty)
        #expect(listing.emptyReason == "Roga can't find /nonexistent/gpg, so it can't list your keys. Type a key ID or fingerprint.")
    }
}
