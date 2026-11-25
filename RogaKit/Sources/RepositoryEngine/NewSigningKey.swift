import Foundation
import GitCore
import GitRunner

/// Making a key to sign commits with, from New SSH Key… and New OpenPGP
/// Key… in the Key field's menu (decision 108). Either is Ed25519 without a
/// passphrase, since git can't ask for one when Roga or an agent commits,
/// and an OpenPGP key doesn't expire. A new SSH key also goes in the allowed
/// signers file, as Trust This Key… would add it (decision 107), so that git
/// says the commits it signs are good.
public enum NewSigningKey {
    /// What making a key runs, shown before it runs.
    public struct Plan: Sendable, Hashable {
        public var format: CommitIdentity.SigningFormat
        /// The email the key is for: an SSH key's comment, and in an OpenPGP
        /// key's user ID.
        public var email: String
        /// An OpenPGP key's user ID, as in `Sam Rivera <sam@rivera.dev>`.
        public var userID: String
        /// The program that makes it, by its full path.
        public var program: String
        /// What it's run with.
        public var arguments: [String]
        /// The same, with `~` for the home folder, for showing.
        public var shownArguments: [String]
        /// An SSH key's private key file, as `~/.ssh/…` and as a path. Its
        /// public key is beside it, with `.pub`.
        public var shownFile: String?
        public var file: String?
        /// Where a new SSH key is trusted.
        public var trust: Trust?

        public init(
            format: CommitIdentity.SigningFormat,
            email: String,
            userID: String,
            program: String,
            arguments: [String],
            shownArguments: [String],
            shownFile: String? = nil,
            file: String? = nil,
            trust: Trust? = nil
        ) {
            self.format = format
            self.email = email
            self.userID = userID
            self.program = program
            self.arguments = arguments
            self.shownArguments = shownArguments
            self.shownFile = shownFile
            self.file = file
            self.trust = trust
        }

        /// The command, as the confirm shows it.
        public var command: ProgramCommand {
            ProgramCommand(program, shownArguments)
        }
    }

    /// The allowed signers file a new SSH key goes in.
    public struct Trust: Sendable, Hashable {
        public var shownFile: String
        public var file: String
        /// Whether `gpg.ssh.allowedSignersFile` has to be set first.
        public var setsFile: Bool

        public init(shownFile: String, file: String, setsFile: Bool) {
            self.shownFile = shownFile
            self.file = file
            self.setsFile = setsFile
        }

        /// What it runs before adding the line, by its arguments after `git`.
        public var configArguments: [String]? {
            setsFile ? ["config", "--global", "gpg.ssh.allowedSignersFile", AllowedSigners.defaultFile] : nil
        }
    }

    /// A plan, or why Roga can't make a key of the format.
    public enum Planned: Sendable, Hashable {
        case ready(Plan)
        case unavailable(String)
    }

    /// The key once it's made.
    public struct Made: Sendable, Hashable {
        public var format: CommitIdentity.SigningFormat
        /// The key as the menu lists it, whose value goes in the Key field.
        public var key: SigningKey
        /// The public half, to copy: the `.pub` file's line, or what
        /// `gpg --armor --export` prints.
        public var publicKey: String
        /// An SSH key's `.pub` file, as a path and as `~/.ssh/…`.
        public var publicKeyFile: String?
        public var shownPublicKeyFile: String?
        /// Why trusting a new SSH key failed, after the key was made.
        public var trustFailure: String?

        public init(
            format: CommitIdentity.SigningFormat,
            key: SigningKey,
            publicKey: String,
            publicKeyFile: String? = nil,
            shownPublicKeyFile: String? = nil,
            trustFailure: String? = nil
        ) {
            self.format = format
            self.key = key
            self.publicKey = publicKey
            self.publicKeyFile = publicKeyFile
            self.shownPublicKeyFile = shownPublicKeyFile
            self.trustFailure = trustFailure
        }
    }

    /// Why making a key failed, in the program's words.
    public struct Failure: Error, Sendable, Hashable, CustomStringConvertible {
        public var description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    /// The name an SSH key gets in `~/.ssh` when nothing there has it, so
    /// that it never replaces a key and isn't the one `ssh` tries first for
    /// logging in.
    public static let sshName = "id_ed25519_signing"

    /// What making a key of a format would run, for the identity's name and
    /// email, with the programs git config in `directory` names.
    ///
    /// - Parameter home: The folder whose `.ssh` gets an SSH key.
    @concurrent
    public static func plan(
        _ format: CommitIdentity.SigningFormat,
        name: String,
        email: String,
        git: Git,
        programs: Programs,
        in directory: String,
        home: String = NSHomeDirectory()
    ) async -> Planned {
        let email = email.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else { return .unavailable("Add an email first, since the key is made for it.") }
        let found = await SigningPrograms.find(git: git, programs: programs, in: directory)
        switch format {
        case .x509:
            return .unavailable("Roga makes SSH and OpenPGP keys. An X.509 certificate comes from whoever issues it.")
        case .ssh:
            if (found.ssh.named as NSString).lastPathComponent == "op-ssh-sign" {
                return .unavailable("gpg.ssh.program is 1Password's op-ssh-sign, which signs only with keys in 1Password, so make the key there.")
            }
            guard let keygen = SigningKeys.find("ssh-keygen", programs: programs, wellKnown: ["/usr/bin/ssh-keygen"]) else {
                return .unavailable("Roga can't find ssh-keygen, which makes SSH keys.")
            }
            let folder = (home as NSString).appendingPathComponent(".ssh")
            let name = freeName(in: folder)
            let file = (folder as NSString).appendingPathComponent(name)
            let shown = "~/.ssh/" + name
            let place = await AllowedSigners.destination(git: git, in: directory, home: home)
            let start = ["-q", "-t", "ed25519", "-C", email, "-N", "", "-f"]
            return .ready(Plan(
                format: .ssh,
                email: email,
                userID: email,
                program: keygen,
                arguments: start + [file],
                shownArguments: start + [shown],
                shownFile: shown,
                file: file,
                trust: Trust(shownFile: place.shownFile, file: place.file, setsFile: place.setsFile)
            ))
        case .openPGP:
            guard let gpg = found.openPGP.path else {
                return .unavailable(found.openPGP.warning ?? "Roga can't find gpg.")
            }
            let userID = name.isEmpty ? email : "\(name) <\(email)>"
            // --yes makes it even when a key has the same user ID, and
            // --status-fd says which key it made.
            let arguments = ["--batch", "--yes", "--passphrase", "", "--status-fd", "1", "--quick-generate-key", userID, "ed25519", "sign", "never"]
            return .ready(Plan(format: .openPGP, email: email, userID: userID, program: gpg, arguments: arguments, shownArguments: arguments))
        }
    }

    /// Makes the key as the plan says, and trusts a new SSH key. A failure
    /// to trust it doesn't undo the key, and `Made` says why.
    ///
    /// - Throws: `Failure` when the program couldn't make the key.
    @concurrent
    public static func make(_ plan: Plan, git: Git, programs: Programs) async throws -> Made {
        switch plan.format {
        case .ssh: try await makeSSH(plan, git: git, programs: programs)
        case .openPGP: try await makeOpenPGP(plan, programs: programs)
        case .x509: throw Failure("Roga doesn't make X.509 certificates.")
        }
    }

    private static func makeSSH(_ plan: Plan, git: Git, programs: Programs) async throws -> Made {
        guard let file = plan.file, let shown = plan.shownFile else { throw Failure("The plan has no file for the key.") }
        let manager = FileManager.default
        let folder = (file as NSString).deletingLastPathComponent
        if !manager.fileExists(atPath: folder) {
            try manager.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // ssh-keygen would ask before replacing it, which nobody could answer.
        guard !manager.fileExists(atPath: file), !manager.fileExists(atPath: file + ".pub") else {
            throw Failure("\(shown) is already there.")
        }
        var command = ProgramCommand(plan.program, plan.arguments)
        command.timeout = .seconds(30)
        try check(try await programs.run(command), named: "ssh-keygen")
        let text = try String(contentsOfFile: file + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = SSHPublicKeyParser.parse(text) else { throw Failure("ssh-keygen made \(shown).pub, but Roga can't read it.") }
        let listed = SigningKeys.fileKey(key, shown: shown + ".pub")

        var trustFailure: String?
        if let trust = plan.trust {
            let offer = AllowedSigners.Offer(
                key: key,
                localKey: listed,
                email: plan.email,
                shownFile: trust.shownFile,
                file: trust.file,
                setsFile: trust.setsFile
            )
            do {
                try await AllowedSigners.trust(offer, git: git)
            } catch {
                trustFailure = String(describing: error)
            }
        }
        return Made(
            format: .ssh,
            key: listed,
            publicKey: text,
            publicKeyFile: file + ".pub",
            shownPublicKeyFile: shown + ".pub",
            trustFailure: trustFailure
        )
    }

    private static func makeOpenPGP(_ plan: Plan, programs: Programs) async throws -> Made {
        var command = ProgramCommand(plan.program, plan.arguments)
        // Making a key waits for enough randomness, and gpg may start its
        // agent first.
        command.timeout = .seconds(60)
        let result = try await programs.run(command)
        try check(result, named: "gpg")
        guard let fingerprint = OpenPGPStatusParser.createdKey(in: result.text) else {
            throw Failure("gpg didn't say which key it made.")
        }

        var list = ProgramCommand(plan.program, OpenPGPKeyParser.arguments + [fingerprint])
        list.timeout = .seconds(15)
        let listed = (try? await programs.run(list)).map { OpenPGPKeyParser.parse($0.text) } ?? []
        let key = listed.first { $0.fingerprint == fingerprint }.map(SigningKeys.openPGPKey) ?? SigningKey(
            value: fingerprint,
            title: plan.userID,
            details: ["ED25519", String(fingerprint.suffix(16))],
            fingerprint: fingerprint,
            emails: [plan.email]
        )

        var export = ProgramCommand(plan.program, ["--armor", "--export", fingerprint])
        export.timeout = .seconds(15)
        let exported = try await programs.run(export)
        try check(exported, named: "gpg")
        return Made(format: .openPGP, key: key, publicKey: exported.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The first of `id_ed25519_signing`, `id_ed25519_signing_2` and so on
    /// that has no private or public key in the folder.
    static func freeName(in folder: String) -> String {
        let manager = FileManager.default
        for number in 1...999 {
            let name = number == 1 ? sshName : "\(sshName)_\(number)"
            let path = (folder as NSString).appendingPathComponent(name)
            if !manager.fileExists(atPath: path), !manager.fileExists(atPath: path + ".pub") { return name }
        }
        return "\(sshName)_\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func check(_ result: ProgramResult, named: String) throws {
        guard !result.succeeded else { return }
        let words = result.errorOutput.split(whereSeparator: \.isNewline).last.map(String.init) ?? "it exited with \(result.status)"
        throw Failure("\(named) didn't make the key: \(words)")
    }
}

extension RepositorySession {
    /// What making a key would run, with the programs the repository's
    /// config names (decision 108).
    @concurrent
    public nonisolated func newKeyPlan(_ format: CommitIdentity.SigningFormat, name: String, email: String) async -> NewSigningKey.Planned {
        await NewSigningKey.plan(format, name: name, email: email, git: git, programs: Programs(sharingWith: git), in: location.commonDirectory)
    }

    /// Makes the key the plan says (decision 108).
    @concurrent
    public nonisolated func makeKey(_ plan: NewSigningKey.Plan) async throws -> NewSigningKey.Made {
        try await NewSigningKey.make(plan, git: git, programs: Programs(sharingWith: git))
    }
}
