import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Commits signed with an SSH key that the test makes, and checking them
/// (decision 104).
@Suite(.timeLimit(.minutes(1)))
struct SignatureCheckTests {
    struct Signed {
        var folder: String
        var repository: String
        var publicKey: String
        var signed: ObjectID
        var unsigned: ObjectID
    }

    func signedRepository() async throws -> Signed {
        let folder = try makeTemporaryFolder()
        let repository = folder + "/work"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", in: repository)
        let key = folder + "/key"
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", key])
        let identity = ["-c", "user.name=T", "-c", "user.email=t@example.com"]
        let signing = ["-c", "gpg.format=ssh", "-c", "user.signingkey=\(key).pub", "-c", "commit.gpgsign=true"]
        _ = try await TestGit.make().run(GitCommand(identity + ["commit", "--quiet", "--allow-empty", "-m", "Unsigned"], in: repository))
        let unsigned = try #require(ObjectID(hex: try await runGit("rev-parse", "HEAD", in: repository).trimmingCharacters(in: .whitespacesAndNewlines)))
        _ = try await TestGit.make().run(GitCommand(identity + signing + ["commit", "--quiet", "--allow-empty", "-m", "Signed"], in: repository))
        let signed = try #require(ObjectID(hex: try await runGit("rev-parse", "HEAD", in: repository).trimmingCharacters(in: .whitespacesAndNewlines)))
        let publicKey = try String(contentsOfFile: key + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return Signed(folder: folder, repository: repository, publicKey: publicKey, signed: signed, unsigned: unsigned)
    }

    func run(_ program: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: program)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    @Test func readsWhichCommitsAreSignedFromTheirHeaders() async throws {
        let signed = try await signedRepository()
        let session = try await openSession(signed.repository)
        let commits = try await session.commits([signed.signed, signed.unsigned])
        #expect(commits[0]?.signatureFormat == .ssh)
        #expect(commits[0]?.isSigned == true)
        #expect(commits[0]?.message == "Signed\n")
        #expect(commits[1]?.signatureFormat == nil)
    }

    @Test func cantCheckAnSSHSignatureWithoutAllowedSigners() async throws {
        let signed = try await signedRepository()
        let session = try await openSession(signed.repository)
        #expect(try await session.checkSignature(of: signed.signed).result == .notChecked)
        #expect(try await session.checkSignature(of: signed.unsigned).result == .notChecked)
    }

    @Test func checksAnSSHSignatureAgainstAllowedSigners() async throws {
        let signed = try await signedRepository()
        let allowed = signed.folder + "/allowed_signers"
        try "t@example.com namespaces=\"git\" \(signed.publicKey)\n".write(toFile: allowed, atomically: true, encoding: .utf8)
        try await runGit("config", "gpg.ssh.allowedSignersFile", allowed, in: signed.repository)
        let session = try await openSession(signed.repository)

        let check = try await session.checkSignature(of: signed.signed)
        #expect(check.result == .good)
        #expect(check.signer == "t@example.com")
        #expect(check.key?.hasPrefix("SHA256:") == true)
    }

    @Test func saysAKeyTheAllowedSignersDontListIsntTrusted() async throws {
        let signed = try await signedRepository()
        let other = signed.folder + "/other"
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "other", "-f", other])
        let otherKey = try String(contentsOfFile: other + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = signed.folder + "/allowed_signers"
        try "someone@example.com namespaces=\"git\" \(otherKey)\n".write(toFile: allowed, atomically: true, encoding: .utf8)
        try await runGit("config", "gpg.ssh.allowedSignersFile", allowed, in: signed.repository)
        let session = try await openSession(signed.repository)

        #expect(try await session.checkSignature(of: signed.signed).result == .untrusted)
    }

    @Test func readsGitsLetters() throws {
        func parse(_ text: String) throws -> SignatureCheck { try SignatureCheckParser.parse(Array(text.utf8)) }
        #expect(try parse("G\0sam@rivera.dev\0SHA256:abc\n") == SignatureCheck(result: .good, signer: "sam@rivera.dev", key: "SHA256:abc"))
        #expect(try parse("B\0\0\n").result == .bad)
        #expect(try parse("Y\0Sam\03AA5C34371567BD2\n").result == .expired)
        #expect(try parse("E\0\03AA5C34371567BD2\n") == SignatureCheck(result: .missingKey, key: "3AA5C34371567BD2"))
        #expect(throws: ParseError.self) { try parse("Q\0\0\n") }
        #expect(throws: ParseError.self) { try parse("G\n") }
    }
}
