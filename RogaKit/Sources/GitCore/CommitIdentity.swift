import Foundation

/// Who a repository's commits go out as, and whether they're signed, as git's
/// config says for it (decision 103). Roga reads it with one `git config` and
/// changes it with `git config`, so it keeps no profiles of its own.
public struct CommitIdentity: Sendable, Hashable {
    /// A setting's value, and where git found it.
    public struct Setting: Sendable, Hashable {
        /// The value as git printed it, or nil for a key with no `=` after
        /// it, which git reads as true.
        public var value: String?
        public var origin: ConfigOrigin

        public init(_ value: String?, origin: ConfigOrigin) {
            self.value = value
            self.origin = origin
        }

        /// The value, unless it's missing or only spaces.
        var text: String? {
            guard let value, !value.allSatisfy(\.isWhitespace) else { return nil }
            return value
        }
    }

    /// How commits are signed, from `gpg.format`.
    public enum SigningFormat: String, Sendable, Hashable, CaseIterable {
        case openPGP = "openpgp"
        case ssh
        case x509

        /// What the format is called.
        public var title: String {
            switch self {
            case .openPGP: "OpenPGP"
            case .ssh: "SSH"
            case .x509: "X.509"
            }
        }
    }

    /// What would go wrong with a commit made now.
    public enum Problem: Sendable, Hashable {
        /// No `user.email`, so git refuses to commit or makes one up from
        /// the login and the Mac's name.
        case noEmail
        /// Commits are signed with SSH, but nothing says which key, so a
        /// commit would stop at signing. OpenPGP and X.509 pick a key from
        /// the committer's email, so they don't need one.
        case noSigningKey
    }

    /// `user.name`
    public var name: Setting?
    /// `user.email`
    public var email: Setting?
    /// `user.signingkey`
    public var signingKey: Setting?
    /// `commit.gpgsign`
    public var signsCommits: Setting?
    /// `gpg.format`
    public var signingFormat: Setting?
    /// `gpg.ssh.defaultKeyCommand`, which picks an SSH key when no key is set.
    public var defaultKeyCommand: Setting?

    public init(
        name: Setting? = nil,
        email: Setting? = nil,
        signingKey: Setting? = nil,
        signsCommits: Setting? = nil,
        signingFormat: Setting? = nil,
        defaultKeyCommand: Setting? = nil
    ) {
        self.name = name
        self.email = email
        self.signingKey = signingKey
        self.signsCommits = signsCommits
        self.signingFormat = signingFormat
        self.defaultKeyCommand = defaultKeyCommand
    }

    /// The name commits carry, when one is set.
    public var shownName: String? { name?.text }
    /// The email commits carry, when one is set.
    public var shownEmail: String? { email?.text }
    /// The key that signs, when one is set.
    public var key: String? { signingKey?.text }
    /// Whether `gpg.ssh.defaultKeyCommand` picks an SSH key when none is set.
    public var hasDefaultKeyCommand: Bool { defaultKeyCommand?.text != nil }

    /// Whether commits are signed, as git reads `commit.gpgsign`.
    public var signs: Bool {
        guard let signsCommits else { return false }
        return Self.isTrue(signsCommits.value)
    }

    /// How commits would be signed, which is OpenPGP unless `gpg.format`
    /// says otherwise.
    public var format: SigningFormat {
        signingFormat?.text.flatMap { SigningFormat(rawValue: $0.lowercased()) } ?? .openPGP
    }

    /// What would go wrong with a commit made now, or nil when nothing would.
    public var problem: Problem? {
        if shownEmail == nil { return .noEmail }
        if signs, format == .ssh, key == nil, !hasDefaultKeyCommand { return .noSigningKey }
        return nil
    }

    /// Whether commits made with `other` would carry the same name and email.
    /// Emails compare without case, as hosting sites match them.
    public func commitsAsSame(as other: CommitIdentity) -> Bool {
        shownName == other.shownName && shownEmail?.lowercased() == other.shownEmail?.lowercased()
    }

    /// How git reads a boolean: a key with no `=` is true, and so are `true`,
    /// `yes`, `on` and any number but 0.
    static func isTrue(_ value: String?) -> Bool {
        guard let value else { return true }
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off", "": return false
        default: return Int(value.trimmingCharacters(in: .whitespaces)).map { $0 != 0 } ?? false
        }
    }
}

/// Where git found a setting, as `git config --show-scope --show-origin` says.
public struct ConfigOrigin: Sendable, Hashable {
    /// Which of git's places the setting comes from. A file that another
    /// includes has the scope of the one that includes it.
    public enum Scope: String, Sendable, Hashable {
        case system
        case global
        /// The repository's own config.
        case local
        /// A worktree's `config.worktree`, with `extensions.worktreeConfig`.
        case worktree
        /// `git -c` or `GIT_CONFIG_PARAMETERS`.
        case command
        case unknown
    }

    public var scope: Scope
    /// The file the setting is in, as git names it, or nil when it isn't in a
    /// file, as for `git -c`. git names the repository's own config by a path
    /// from where it runs, such as `config` in the git directory.
    public var file: String?

    public init(scope: Scope, file: String? = nil) {
        self.scope = scope
        self.file = file
    }
}
