import Foundation
import GitCore
import GitRunner

/// The public half of the key that made a commit's signature, which the
/// commit panel's Signature line copies and adds to GitHub or GitLab
/// (decision 117). An SSH signature carries its key, so Roga reads it from
/// the commit. An OpenPGP signature only names its key, so gpg exports it,
/// which it can only do when the key is in its keyring.
public enum SignaturePublicKey {
    /// The key, ready for adding to a host as a key Roga made would be, and
    /// whether it's one of this Mac's keys.
    public struct Found: Sendable, Hashable {
        /// The key as `NewSigningKey.Made` carries a new one, so that adding
        /// it to a host works the same way.
        public var key: NewSigningKey.Made
        /// Whether it's one of the keys this Mac signs with, as the Key field
        /// lists them (decision 106). A key from another Mac is fine to add
        /// when it's the person's own, so this only changes what Roga says.
        public var isThisMacs: Bool

        public init(key: NewSigningKey.Made, isThisMacs: Bool) {
            self.key = key
            self.isThisMacs = isThisMacs
        }
    }

    /// The public half as GitHub and GitLab take it when it's pasted: an SSH
    /// key's line, as in `ssh-ed25519 AAAA…`, or an OpenPGP key's armored
    /// export.
    ///
    /// - Throws: `NewSigningKey.Failure` when gpg isn't here or doesn't have
    ///   the key, and for X.509, whose certificate isn't read.
    @concurrent
    public static func text(
        of key: SignatureKey,
        format: CommitIdentity.SigningFormat,
        git: Git,
        programs: Programs,
        in directory: String
    ) async throws -> String {
        switch format {
        case .ssh:
            guard let ssh = key.ssh else { throw NewSigningKey.Failure("Roga couldn't read the key from the signature.") }
            return ssh.line
        case .openPGP:
            return try await export(key.id, git: git, programs: programs, in: directory)
        case .x509:
            throw NewSigningKey.Failure("Roga doesn't read X.509 certificates.")
        }
    }

    /// The key, with the `.pub` file it's in when it's one of this Mac's, so
    /// that gh adds it from there.
    ///
    /// - Parameter home: The folder whose `.ssh` has this Mac's keys.
    /// - Throws: As `text(of:format:git:programs:in:)` does.
    @concurrent
    public static func find(
        _ key: SignatureKey,
        format: CommitIdentity.SigningFormat,
        git: Git,
        programs: Programs,
        in directory: String,
        home: String = NSHomeDirectory()
    ) async throws -> Found {
        let publicKey = try await text(of: key, format: format, git: git, programs: programs, in: directory)
        let keys = await SigningKeys.list(format, git: git, programs: programs, in: directory, home: home).keys
        switch format {
        case .ssh:
            guard let ssh = key.ssh else { throw NewSigningKey.Failure("Roga couldn't read the key from the signature.") }
            guard let local = keys.first(where: { $0.fingerprint == ssh.fingerprint }) else {
                let listed = SigningKey(value: ssh.literal, title: "\(ssh.typeName) key", details: [ssh.typeName], fingerprint: ssh.fingerprint, emails: [])
                return Found(key: NewSigningKey.Made(format: .ssh, key: listed, publicKey: publicKey), isThisMacs: false)
            }
            // A key in a .pub file keeps its comment, and gh adds it from the file.
            if local.value.hasPrefix("~/"), local.value.hasSuffix(".pub") {
                let file = (home as NSString).appendingPathComponent(String(local.value.dropFirst(2)))
                let line = (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { SSHPublicKeyParser.parseLines($0).first }
                if let line, line.fingerprint == ssh.fingerprint {
                    let made = NewSigningKey.Made(format: .ssh, key: local, publicKey: line.line, publicKeyFile: file, shownPublicKeyFile: local.value)
                    return Found(key: made, isThisMacs: true)
                }
            }
            return Found(key: NewSigningKey.Made(format: .ssh, key: local, publicKey: publicKey), isThisMacs: true)
        case .openPGP:
            let id = key.id.uppercased()
            let local = keys.first { $0.fingerprint.uppercased().hasSuffix(id) }
            let listed = local ?? SigningKey(value: key.id, title: key.id, details: [], fingerprint: key.id, emails: [])
            return Found(key: NewSigningKey.Made(format: .openPGP, key: listed, publicKey: publicKey), isThisMacs: local != nil)
        case .x509:
            throw NewSigningKey.Failure("Roga doesn't read X.509 certificates.")
        }
    }

    /// What `gpg --armor --export` prints for the key, with the program git
    /// config names. gpg prints nothing and still succeeds when it doesn't
    /// have the key.
    private static func export(_ id: String, git: Git, programs: Programs, in directory: String) async throws -> String {
        let found = await SigningPrograms.find(git: git, programs: programs, in: directory)
        guard let gpg = found.openPGP.path else {
            throw NewSigningKey.Failure(found.openPGP.warning ?? "Roga can't find gpg, which has the key's public half.")
        }
        var command = ProgramCommand(gpg, exportArguments(id))
        // The first run can wait while gpg starts its agent.
        command.timeout = .seconds(15)
        let result = try await programs.run(command)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !text.isEmpty else {
            throw NewSigningKey.Failure("gpg doesn't have the key \(id), so Roga can't copy its public half.")
        }
        return text
    }

    /// What exporting an OpenPGP key runs, by its arguments after `gpg`.
    public static func exportArguments(_ id: String) -> [String] {
        ["--armor", "--export", id]
    }
}

extension RepositorySession {
    /// The public half of the key that made a commit's signature, to copy
    /// (decision 117).
    @concurrent
    public nonisolated func publicKey(of key: SignatureKey, format: CommitIdentity.SigningFormat) async throws -> String {
        try await SignaturePublicKey.text(of: key, format: format, git: git, programs: Programs(sharingWith: git), in: location.commonDirectory)
    }

    /// The key that made a commit's signature, ready for adding to a host,
    /// and whether it's one of this Mac's (decision 117).
    @concurrent
    public nonisolated func publicKeyToAdd(_ key: SignatureKey, format: CommitIdentity.SigningFormat) async throws -> SignaturePublicKey.Found {
        try await SignaturePublicKey.find(key, format: format, git: git, programs: Programs(sharingWith: git), in: location.commonDirectory)
    }

    /// Adds a key to the host with gh (decisions 108 and 117).
    @concurrent
    public nonisolated func addKey(_ made: NewSigningKey.Made, to host: KeyHost, gh: String) async throws {
        try await GitHubCLI.add(made, to: host.host, title: GitHubCLI.title, gh: gh, programs: Programs(sharingWith: git))
    }

    /// The hosts the repository's remotes are on, without asking gh which
    /// GitHub Enterprise hosts it's signed in to, for naming the Signature
    /// line's Add to GitHub… before anything is run (decision 117).
    @concurrent
    public nonisolated func remoteKeyHosts() async -> [KeyHost] {
        KeyHost.hosts(remoteURLs: (try? await remoteURLs()) ?? [:])
    }
}
