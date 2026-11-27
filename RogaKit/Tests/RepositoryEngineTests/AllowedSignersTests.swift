import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Trusting the user's own SSH key for checking signatures, with keys and a
/// home folder the tests make (decision 107).
@Suite(.timeLimit(.minutes(1)))
struct AllowedSignersTests {
    struct Signed {
        var home: String
        var repository: String
        var git: Git
        var session: RepositorySession
        var commit: ObjectID
        var raw: String
    }

    func run(_ program: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: program)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    /// Programs that see no agent.
    let programs = Programs(searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", environment: ["SSH_AUTH_SOCK": "/nonexistent"])

    /// A repository with one commit signed with `key`, and a git whose home
    /// and global config are the test's own.
    func signed(with key: String = "id_ed25519", inSSH: Bool = true) async throws -> Signed {
        let home = try makeTemporaryFolder()
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        try "".write(toFile: home + "/.gitconfig", atomically: true, encoding: .utf8)
        let keyPath = (inSSH ? home + "/.ssh/" : home + "/") + key
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "t@example.com", "-f", keyPath])
        let repository = home + "/work"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        let git = Git(
            installation: try await TestGit.installation(),
            environment: TestGit.isolatedEnvironment.merging(["HOME": home, "GIT_CONFIG_GLOBAL": home + "/.gitconfig"]) { $1 }
        )
        _ = try await git.run(GitCommand(["init", "--quiet"], in: repository))
        let settings = ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "gpg.format=ssh", "-c", "user.signingkey=\(keyPath).pub", "-c", "commit.gpgsign=true"]
        _ = try await git.run(GitCommand(settings + ["commit", "--quiet", "--allow-empty", "-m", "Signed"], in: repository))
        let session = try await RepositorySession.open(containing: repository, git: git)
        let hex = try await git.text(GitCommand(["rev-parse", "HEAD"], in: repository)).trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try #require(ObjectID(hex: hex))
        let raw = try await git.text(GitCommand(["cat-file", "commit", hex], in: repository))
        return Signed(home: home, repository: repository, git: git, session: session, commit: commit, raw: raw)
    }

    func makeOffer(_ signed: Signed, email: String = "t@example.com") async -> AllowedSigners.Offer? {
        await AllowedSigners.offer(forCommit: signed.raw, email: email, git: signed.git, programs: programs, in: signed.repository, home: signed.home)
    }

    @Test func trustsThisMacsKeyAndPointsGitAtTheFile() async throws {
        let signed = try await signed()
        #expect(try await signed.session.checkSignature(of: signed.commit).result == .notChecked)

        let offer = try #require(await makeOffer(signed))
        #expect(offer.setsFile)
        #expect(offer.shownFile == "~/.ssh/allowed_signers")
        #expect(offer.localKey.title == "~/.ssh/id_ed25519.pub")
        #expect(offer.line.hasPrefix("t@example.com namespaces=\"git\" ssh-ed25519 AAAA"))
        #expect(offer.configArguments == ["config", "--global", "gpg.ssh.allowedSignersFile", "~/.ssh/allowed_signers"])

        try await AllowedSigners.trust(offer, git: signed.git)
        let check = try await signed.session.checkSignature(of: signed.commit)
        #expect(check.result == .good)
        #expect(check.signer == "t@example.com")
        // The key read from the signature before checking is the one git
        // names after, so the commit panel's line doesn't change (decision 109).
        #expect(await signed.session.signatureKey(of: signed.commit)?.id == check.key)
        // Once the file lists it, there's nothing left to offer.
        #expect(await makeOffer(signed) == nil)
    }

    @Test func addsToTheFileGitAlreadyReads() async throws {
        let signed = try await signed()
        let file = signed.home + "/trusted"
        try "someone@example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEl5c7+FTBhBHYT9TKz61AWx/U3+VjN1Mh2idso8ynyp".write(toFile: file, atomically: true, encoding: .utf8)
        _ = try await signed.git.run(GitCommand(["config", "--global", "gpg.ssh.allowedSignersFile", file], in: "/"))
        #expect(try await signed.session.checkSignature(of: signed.commit).result == .untrusted)

        let offer = try #require(await makeOffer(signed))
        #expect(!offer.setsFile)
        #expect(offer.file == file)
        try await AllowedSigners.trust(offer, git: signed.git)
        #expect(try await signed.session.checkSignature(of: signed.commit).result == .good)
        // The line that was there stays, and the new one starts a line of its own.
        let lines = try String(contentsOfFile: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("someone@example.com "))
        #expect(lines[1].hasPrefix("t@example.com namespaces=\"git\" "))
    }

    @Test func offersNothingForAKeyThatIsntThisMacs() async throws {
        let signed = try await signed(with: "elsewhere", inSSH: false)
        #expect(await makeOffer(signed) == nil)
    }

    @Test func offersNothingWithoutAnEmail() async throws {
        let signed = try await signed()
        #expect(await makeOffer(signed, email: "") == nil)
    }

    /// The Signature line's menu copies and adds the key that signed the
    /// commit, which is the key in this Mac's `.pub` file (decision 117).
    @Test func findsThisMacsKeyForAddingToAHost() async throws {
        let signed = try await signed()
        let key = try #require(await signed.session.signatureKey(of: signed.commit))
        let file = try String(contentsOfFile: signed.home + "/.ssh/id_ed25519.pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        // Copying reads the signature, which has the key without its comment.
        let copied = try await SignaturePublicKey.text(of: key, format: .ssh, git: signed.git, programs: programs, in: signed.repository)
        #expect(file.hasPrefix(copied + " "))

        let found = try await SignaturePublicKey.find(key, format: .ssh, git: signed.git, programs: programs, in: signed.repository, home: signed.home)
        #expect(found.isThisMacs)
        #expect(found.key.publicKey == file)
        #expect(found.key.publicKeyFile == signed.home + "/.ssh/id_ed25519.pub")
        #expect(found.key.shownPublicKeyFile == "~/.ssh/id_ed25519.pub")
        #expect(!GitHubCLI.pipesKey(found.key))
    }

    @Test func findsAnotherMacsKeyForAddingToAHost() async throws {
        let signed = try await signed(with: "elsewhere", inSSH: false)
        let key = try #require(await signed.session.signatureKey(of: signed.commit))
        let found = try await SignaturePublicKey.find(key, format: .ssh, git: signed.git, programs: programs, in: signed.repository, home: signed.home)
        #expect(!found.isThisMacs)
        #expect(found.key.publicKey == key.ssh?.line)
        #expect(found.key.publicKeyFile == nil)
        // gh takes it on standard input, since it's in no file here.
        #expect(GitHubCLI.pipesKey(found.key))
        await #expect(throws: NewSigningKey.Failure.self) {
            try await SignaturePublicKey.text(of: key, format: .x509, git: signed.git, programs: programs, in: signed.repository)
        }
    }

    @Test func readsTheKeyFromTheSignature() async throws {
        let signed = try await signed()
        let signature = try #require(SSHSignatureParser.signature(inCommit: signed.raw))
        #expect(signature.hasPrefix("-----BEGIN SSH SIGNATURE-----"))
        #expect(signature.hasSuffix("-----END SSH SIGNATURE-----"))
        let key = try #require(SSHSignatureParser.publicKey(inSignature: signature))
        let file = try String(contentsOfFile: signed.home + "/.ssh/id_ed25519.pub", encoding: .utf8)
        #expect(key.fingerprint == SSHPublicKeyParser.parse(file)?.fingerprint)
    }
}
