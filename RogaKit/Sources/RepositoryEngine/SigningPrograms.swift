import Foundation
import GitCore
import GitRunner

/// The program git signs with for each format, and whether it's on this Mac
/// (decision 108): `ssh-keygen` for SSH, `gpg` for OpenPGP and `gpgsm` for
/// X.509, or whatever git config names instead. The identity popover and
/// Settings › Git look each time they show the format, so that a format
/// whose program isn't here can't be chosen, and a program installed later
/// counts at once. Setup's Look Around shows the same with versions.
///
/// It only looks for files, as git would find them, and runs nothing but
/// `git config`, so it's quick. It doesn't run the programs to see whether
/// they work.
public enum SigningPrograms {
    /// One format's program.
    public struct Program: Sendable, Hashable {
        public var format: CommitIdentity.SigningFormat
        /// The name or path git config gives, or git's default.
        public var named: String
        /// The setting that names it, or nil for git's default.
        public var setting: String?
        /// Where Roga found it, or nil when it isn't on this Mac.
        public var path: String?

        public init(format: CommitIdentity.SigningFormat, named: String, setting: String? = nil, path: String?) {
            self.format = format
            self.named = named
            self.setting = setting
            self.path = path
        }

        public var isFound: Bool { path != nil }

        /// What a disabled format's tooltip says, or nil when it's found.
        public var hint: String? {
            guard !isFound else { return nil }
            if let setting { return "Roga can't find \(named), which \(setting) names" }
            switch format {
            case .ssh: return "Roga can't find ssh-keygen"
            case .openPGP: return "Install GnuPG to sign with OpenPGP"
            case .x509: return "Install GnuPG, which has gpgsm, to sign with X.509"
            }
        }

        /// What the popover says when git already signs with a format whose
        /// program isn't here, or nil when it's found.
        public var warning: String? {
            guard !isFound else { return nil }
            let what = setting.map { "\(named), which \($0) names" } ?? named
            let install = format == .ssh || setting != nil ? "" : " Install GnuPG, or sign with SSH."
            return "Roga can't find \(what), so commits would stop at signing.\(install)"
        }
    }

    /// The three formats' programs.
    public struct Found: Sendable, Hashable {
        public var ssh: Program
        public var openPGP: Program
        public var x509: Program

        public init(ssh: Program, openPGP: Program, x509: Program) {
            self.ssh = ssh
            self.openPGP = openPGP
            self.x509 = x509
        }

        public subscript(format: CommitIdentity.SigningFormat) -> Program {
            switch format {
            case .ssh: ssh
            case .openPGP: openPGP
            case .x509: x509
            }
        }
    }

    /// git's own name for each format's program when config names none.
    public static func defaultName(_ format: CommitIdentity.SigningFormat) -> String {
        switch format {
        case .ssh: "ssh-keygen"
        case .openPGP: "gpg"
        case .x509: "gpgsm"
        }
    }

    /// Each format's program, as git config in `directory` names it.
    ///
    /// - Parameter programs: Has git's `PATH`, which git looks in too.
    @concurrent
    public static func find(git: Git, programs: Programs, in directory: String) async -> Found {
        let settings = await gpgSettings(git: git, in: directory)
        func program(_ format: CommitIdentity.SigningFormat, _ keys: [String]) -> Program {
            let setting = keys.first { settings[$0] != nil }
            let named = setting.flatMap { settings[$0] } ?? defaultName(format)
            let wellKnown = format == .ssh ? ["/usr/bin/" + named] : []
            let path = SigningKeys.program(named, programs: programs) ?? wellKnown.first(where: ExecutableSearch.isExecutableFile)
            return Program(format: format, named: named, setting: setting, path: path)
        }
        return Found(
            ssh: program(.ssh, ["gpg.ssh.program"]),
            // git reads gpg.openpgp.program, and gpg.program for the same.
            openPGP: program(.openPGP, ["gpg.openpgp.program", "gpg.program"]),
            x509: program(.x509, ["gpg.x509.program"])
        )
    }

    /// The version setup's Look Around shows for SSH, from the `ssh` beside
    /// `ssh-keygen`, or for OpenPGP, from `gpg --version`. X.509 shows none,
    /// since `gpgsm` comes with GnuPG.
    @concurrent
    public static func version(of program: Program, programs: Programs) async -> String? {
        guard let path = program.path else { return nil }
        switch program.format {
        case .ssh:
            let ssh = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("ssh")
            guard ExecutableSearch.isExecutableFile(ssh) else { return nil }
            var command = ProgramCommand(ssh, ["-V"])
            command.timeout = .seconds(5)
            guard let result = try? await programs.run(command) else { return nil }
            // ssh prints its version to standard error.
            return ProgramVersionParser.openSSH(result.errorOutput) ?? ProgramVersionParser.openSSH(result.text)
        case .openPGP:
            var command = ProgramCommand(path, ["--version"])
            command.timeout = .seconds(5)
            guard let result = try? await programs.run(command), result.succeeded else { return nil }
            return ProgramVersionParser.gpg(result.text)
        case .x509:
            return nil
        }
    }

    /// Every `gpg.*` setting git reads in `directory`, by its key in
    /// lowercase, from one `git config --get-regexp`.
    static func gpgSettings(git: Git, in directory: String) async -> [String: String] {
        var command = GitCommand(["config", "--get-regexp", "^gpg\\."], in: directory)
        command.successStatuses = [0, 1]
        guard let output = try? await git.run(command).output else { return [:] }
        var settings: [String: String] = [:]
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            // The last one git reads wins, as it does for git.
            if !value.isEmpty { settings[key.lowercased()] = value }
        }
        return settings
    }
}

extension RepositorySession {
    /// The program git signs the repository's commits with for each format,
    /// and whether it's on this Mac (decision 108).
    @concurrent
    public nonisolated func signingPrograms() async -> SigningPrograms.Found {
        await SigningPrograms.find(git: git, programs: Programs(sharingWith: git), in: location.commonDirectory)
    }
}
