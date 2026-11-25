import Foundation
import GitCore
import GitRunner

/// Trusting the user's own SSH key for checking signatures, from the commit
/// panel's Signature line (decision 107). git checks an SSH signature only
/// against the file `gpg.ssh.allowedSignersFile` names, so this adds the key
/// to that file for the commit's email, and points git at
/// `~/.ssh/allowed_signers` first when nothing names a file yet.
public enum AllowedSigners {
    /// What trusting the key that signed a commit would do.
    public struct Offer: Sendable, Hashable {
        /// The key, as the commit's signature has it.
        public var key: SSHPublicKey
        /// The same key as this Mac lists it, for its name, such as
        /// `~/.ssh/id_ed25519.pub`.
        public var localKey: SigningKey
        /// The email the key is trusted for: the commit's committer's.
        public var email: String
        /// The file, as git config names it or as Roga will.
        public var shownFile: String
        /// The file's absolute path.
        public var file: String
        /// Whether `gpg.ssh.allowedSignersFile` has to be set first.
        public var setsFile: Bool

        public init(key: SSHPublicKey, localKey: SigningKey, email: String, shownFile: String, file: String, setsFile: Bool) {
            self.key = key
            self.localKey = localKey
            self.email = email
            self.shownFile = shownFile
            self.file = file
            self.setsFile = setsFile
        }

        /// The line it adds to the file.
        public var line: String {
            AllowedSignersFile.line(email: email, key: key)
        }

        /// What it runs before adding the line, by its arguments after `git`.
        public var configArguments: [String]? {
            setsFile ? ["config", "--global", "gpg.ssh.allowedSignersFile", AllowedSigners.defaultFile] : nil
        }
    }

    /// The file Roga points git at when nothing names one, which is where
    /// GitHub's and most guides put it.
    public static let defaultFile = "~/.ssh/allowed_signers"

    /// What trusting the key that signed a commit would do, or nil when the
    /// key isn't one of this Mac's, since vouching for someone else's key is
    /// another question, or when the file already lists it for the email.
    ///
    /// - Parameters:
    ///   - rawCommit: What `git cat-file commit` printed for the commit.
    ///   - email: The committer's email.
    ///   - directory: Where git reads `gpg.ssh.allowedSignersFile`.
    ///   - home: The folder `~` stands for.
    @concurrent
    public static func offer(
        forCommit rawCommit: String,
        email: String,
        git: Git,
        programs: Programs,
        in directory: String,
        home: String = NSHomeDirectory()
    ) async -> Offer? {
        guard !email.isEmpty,
              let signature = SSHSignatureParser.signature(inCommit: rawCommit),
              let key = SSHSignatureParser.publicKey(inSignature: signature)
        else { return nil }
        let keys = await SigningKeys.list(.ssh, git: git, programs: programs, in: directory, home: home).keys
        guard let localKey = keys.first(where: { $0.fingerprint == key.fingerprint }) else { return nil }

        let named = await configValue(["config", "--get", "gpg.ssh.allowedSignersFile"], git: git, in: directory)
        let file: String
        if let path = await configValue(["config", "--get", "--path", "gpg.ssh.allowedSignersFile"], git: git, in: directory) {
            file = path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
        } else {
            file = home + "/" + defaultFile.dropFirst(2)
        }
        if let text = try? String(contentsOfFile: file, encoding: .utf8),
           AllowedSignersFile.lists(key, for: email, in: text)
        {
            return nil
        }
        return Offer(
            key: key,
            localKey: localKey,
            email: email,
            shownFile: named ?? defaultFile,
            file: file,
            setsFile: named == nil
        )
    }

    /// Points git at the file when the offer says to, then adds the line,
    /// making the file and its folder when they're missing. It adds nothing
    /// when the file already lists the key for the email.
    ///
    /// - Throws: `GitError` when git refuses the setting, or a file error.
    @concurrent
    public static func trust(_ offer: Offer, git: Git) async throws {
        if let arguments = offer.configArguments {
            _ = try await git.run(GitCommand(arguments, in: "/"))
        }
        let manager = FileManager.default
        let folder = (offer.file as NSString).deletingLastPathComponent
        if !manager.fileExists(atPath: folder) {
            try manager.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let existing = (try? String(contentsOfFile: offer.file, encoding: .utf8)) ?? ""
        guard !AllowedSignersFile.lists(offer.key, for: offer.email, in: existing) else { return }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + separator + offer.line + "\n").write(toFile: offer.file, atomically: true, encoding: .utf8)
    }

    private static func configValue(_ arguments: [String], git: Git, in directory: String) async -> String? {
        var command = GitCommand(arguments, in: directory)
        command.successStatuses = [0, 1]
        guard let output = try? await git.run(command).output else { return nil }
        let value = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

extension RepositorySession {
    /// What trusting the key that signed a commit would do, or nil when
    /// there's nothing to offer (decision 107).
    @concurrent
    public nonisolated func allowedSignersOffer(for commit: ObjectID, email: String) async -> AllowedSigners.Offer? {
        guard let raw = try? await git.run(GitCommand(["cat-file", "commit", commit.hex], in: location.commonDirectory)).output else { return nil }
        return await AllowedSigners.offer(
            forCommit: String(decoding: raw, as: UTF8.self),
            email: email,
            git: git,
            programs: Programs(sharingWith: git),
            in: location.commonDirectory
        )
    }

    /// Trusts the key, as the offer says (decision 107).
    @concurrent
    public nonisolated func trust(_ offer: AllowedSigners.Offer) async throws {
        try await AllowedSigners.trust(offer, git: git)
    }
}
