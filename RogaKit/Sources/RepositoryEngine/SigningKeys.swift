import Foundation
import GitCore
import GitRunner

/// Finds the keys on this Mac that can sign commits, for the identity's Key
/// field (decision 106), with the programs git itself signs with. It runs
/// only when the popover or Settings shows the Key field, never with the
/// sidebar's look, since `gpg` can take a moment while it starts its agent.
public enum SigningKeys {
    /// The keys for one format, or why there are none.
    public struct Listing: Sendable, Hashable {
        public var keys: [SigningKey]
        /// Why the list is empty, for the line under the field, or nil when
        /// it has keys.
        public var emptyReason: String?

        public init(keys: [SigningKey], emptyReason: String? = nil) {
            self.keys = keys
            self.emptyReason = keys.isEmpty ? emptyReason : nil
        }
    }

    /// The keys for a format, read in `directory`, whose config says which
    /// programs git signs with. X.509 has none, since its certificates are
    /// typed as they are.
    ///
    /// - Parameters:
    ///   - programs: Runs `ssh-add` and `gpg`, with git's `PATH`.
    ///   - home: The folder whose `.ssh` has the keys.
    @concurrent
    public static func list(
        _ format: CommitIdentity.SigningFormat,
        git: Git,
        programs: Programs,
        in directory: String,
        home: String = NSHomeDirectory()
    ) async -> Listing {
        switch format {
        case .ssh: await ssh(git: git, programs: programs, in: directory, home: home)
        case .openPGP: await openPGP(git: git, programs: programs, in: directory)
        case .x509: Listing(keys: [])
        }
    }

    /// The keys first whose comment or user ID names the email, in the order
    /// they were found otherwise.
    public static func ordered(_ keys: [SigningKey], for email: String?) -> [SigningKey] {
        keys.filter { $0.names(email) } + keys.filter { !$0.names(email) }
    }

    // MARK: SSH

    /// The SSH keys `ssh-keygen -Y sign` can use: each `.pub` file in
    /// `~/.ssh` whose private key is beside it or in the agent, then the
    /// agent's other keys. A file is written as its path, and a key that's
    /// only in an agent as `key::` and the key, since git needs one or the
    /// other. When `gpg.ssh.program` is 1Password's `op-ssh-sign`, the keys
    /// in the agent that `~/.ssh/config` names come too, since that program
    /// signs through it; otherwise git couldn't reach them.
    static func ssh(git: Git, programs: Programs, in directory: String, home: String) async -> Listing {
        let folder = (home as NSString).appendingPathComponent(".ssh")
        let sshProgram = await configValue("gpg.ssh.program", git: git, in: directory)
        let usesOnePassword = sshProgram.map { ($0 as NSString).lastPathComponent == "op-ssh-sign" } ?? false
        let agent = await agentKeys(programs: programs, socket: nil)
        let inAgent = Set(agent.map(\.fingerprint))
        var keys: [SigningKey] = []
        var seen: Set<String> = []

        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        for file in files.sorted() where file.hasSuffix(".pub") && !file.hasSuffix("-cert.pub") {
            let path = (folder as NSString).appendingPathComponent(file)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let key = SSHPublicKeyParser.parseLines(text).first
            else { continue }
            let hasPrivateKey = FileManager.default.fileExists(atPath: String(path.dropLast(".pub".count)))
            guard hasPrivateKey || inAgent.contains(key.fingerprint), seen.insert(key.fingerprint).inserted else { continue }
            keys.append(fileKey(key, shown: "~/.ssh/" + file))
        }
        for key in agent where seen.insert(key.fingerprint).inserted {
            keys.append(agentKey(key, place: "in the agent"))
        }

        let config = try? String(contentsOfFile: (folder as NSString).appendingPathComponent("config"), encoding: .utf8)
        let identityAgent = config.flatMap { SSHConfigParser.identityAgent(in: $0, home: home) }
        if usesOnePassword, let identityAgent {
            for key in await agentKeys(programs: programs, socket: identityAgent) where seen.insert(key.fingerprint).inserted {
                keys.append(agentKey(key, place: "in 1Password"))
            }
        }

        let reason = if identityAgent != nil, !usesOnePassword {
            "No keys in ~/.ssh or the agent. The agent ~/.ssh/config names signs only when gpg.ssh.program is its own program, as 1Password's op-ssh-sign is."
        } else {
            "No keys in ~/.ssh or the agent. Make one, or type a key's path."
        }
        return Listing(keys: keys, emptyReason: reason)
    }

    /// A key in a `.pub` file, written as its path, such as
    /// `~/.ssh/id_ed25519.pub`.
    static func fileKey(_ key: SSHPublicKey, shown: String) -> SigningKey {
        SigningKey(
            value: shown,
            title: shown,
            details: [key.typeName] + (key.comment.isEmpty ? [] : [key.comment]) + touch(key),
            fingerprint: key.fingerprint,
            emails: KeyEmails.find(in: key.comment)
        )
    }

    private static func agentKey(_ key: SSHPublicKey, place: String) -> SigningKey {
        SigningKey(
            value: key.literal,
            title: key.comment.isEmpty ? "\(key.typeName) key" : key.comment,
            details: [key.typeName, place] + touch(key),
            fingerprint: key.fingerprint,
            emails: KeyEmails.find(in: key.comment)
        )
    }

    /// A security key asks for a touch for every signature, an agent's
    /// commits included.
    private static func touch(_ key: SSHPublicKey) -> [String] {
        key.isSecurityKey ? ["asks for a touch"] : []
    }

    /// The keys an agent holds, from `ssh-add -L`, which exits with 1 when
    /// it has none and 2 when there's no agent. Both are an empty list.
    ///
    /// - Parameter socket: The agent's socket, or nil for the one
    ///   `SSH_AUTH_SOCK` names, which git's `ssh-keygen` uses too.
    private static func agentKeys(programs: Programs, socket: String?) async -> [SSHPublicKey] {
        guard let sshAdd = find("ssh-add", programs: programs, wellKnown: ["/usr/bin/ssh-add"]) else { return [] }
        var command = ProgramCommand(sshAdd, ["-L"])
        command.timeout = .seconds(5)
        if let socket { command.environment["SSH_AUTH_SOCK"] = socket }
        guard let result = try? await programs.run(command), result.succeeded else { return [] }
        return SSHPublicKeyParser.parseLines(result.text)
    }

    // MARK: OpenPGP

    /// The OpenPGP keys `gpg` can sign with, written as their fingerprints.
    /// It runs the program `gpg.program` names, or `gpg` from git's `PATH`
    /// and where installers put it.
    static func openPGP(git: Git, programs: Programs, in directory: String) async -> Listing {
        let named = await configValue("gpg.program", git: git, in: directory) ?? "gpg"
        guard let gpg = program(named, programs: programs) else {
            return Listing(keys: [], emptyReason: "Roga can't find \(named), so it can't list your keys. Type a key ID or fingerprint.")
        }
        var command = ProgramCommand(gpg, OpenPGPKeyParser.arguments)
        // The first run can wait while gpg starts its agent.
        command.timeout = .seconds(15)
        let result: ProgramResult
        do {
            result = try await programs.run(command)
        } catch {
            return Listing(keys: [], emptyReason: "\(named) didn't list its keys: \(error)")
        }
        guard result.succeeded else {
            let words = result.errorOutput.split(whereSeparator: \.isNewline).last.map(String.init) ?? "it exited with \(result.status)"
            return Listing(keys: [], emptyReason: "\(named) didn't list its keys: \(words)")
        }
        let keys = OpenPGPKeyParser.parse(result.text).map(openPGPKey)
        return Listing(keys: keys, emptyReason: "\(named) has no secret keys that can sign. Make one, or type a key ID.")
    }

    /// An OpenPGP key, written as its fingerprint.
    static func openPGPKey(_ key: OpenPGPSecretKey) -> SigningKey {
        SigningKey(
            value: key.fingerprint,
            title: key.userIDs.first ?? key.keyID,
            details: [key.algorithm, key.keyID] + (key.isOnCard ? ["on a smartcard"] : []),
            fingerprint: key.fingerprint,
            emails: key.userIDs.flatMap { KeyEmails.find(in: $0) }
        )
    }

    // MARK: Finding programs and settings

    /// A program by its path, or by its name through git's `PATH` and then
    /// Homebrew's folders and GPG Suite's.
    static func program(_ named: String, programs: Programs) -> String? {
        if named.hasPrefix("/") { return ExecutableSearch.isExecutableFile(named) ? named : nil }
        let expanded = (named as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return ExecutableSearch.isExecutableFile(expanded) ? expanded : nil }
        let wellKnown = GitInstallation.homebrewDirectories.map { $0 + "/" + named } + ["/usr/local/MacGPG2/bin/" + named]
        return find(named, programs: programs, wellKnown: wellKnown)
    }

    static func find(_ name: String, programs: Programs, wellKnown: [String]) -> String? {
        ExecutableSearch.candidates(named: [name], searchPath: programs.environment["PATH"] ?? "", wellKnown: wellKnown).first
    }

    /// A setting's value as git reads it in `directory`, or nil when it isn't
    /// set or git can't say.
    static func configValue(_ key: String, git: Git, in directory: String) async -> String? {
        var command = GitCommand(["config", "--get", key], in: directory)
        command.successStatuses = [0, 1]
        guard let output = try? await git.run(command).output else { return nil }
        let value = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

extension RepositorySession {
    /// The keys on this Mac that can sign the repository's commits, with
    /// the programs its config says git signs with (decision 106).
    @concurrent
    public nonisolated func signingKeys(_ format: CommitIdentity.SigningFormat) async -> SigningKeys.Listing {
        await SigningKeys.list(format, git: git, programs: Programs(sharingWith: git), in: location.commonDirectory)
    }
}
