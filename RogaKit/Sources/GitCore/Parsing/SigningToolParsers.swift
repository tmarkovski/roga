import Foundation

/// An account gh is signed in to, as `gh auth status` lists it, with the
/// scopes its token has (decision 108).
public struct GitHubAccount: Sendable, Hashable {
    public var host: String
    public var scopes: Set<String>

    public init(host: String, scopes: Set<String>) {
        self.host = host
        self.scopes = scopes
    }

    /// The scope gh asks for before it adds a signing key of a format, which
    /// a default `gh auth login` doesn't have.
    public static func scope(for format: CommitIdentity.SigningFormat) -> String {
        format == .openPGP ? "admin:gpg_key" : "admin:ssh_signing_key"
    }

    /// Whether gh may add a signing key of a format to this account. GitHub
    /// takes the scope that writes keys, which the admin scope includes.
    public func canAdd(_ format: CommitIdentity.SigningFormat) -> Bool {
        switch format {
        case .ssh: !scopes.isDisjoint(with: ["admin:ssh_signing_key", "write:ssh_signing_key"])
        case .openPGP: !scopes.isDisjoint(with: ["admin:gpg_key", "write:gpg_key"])
        case .x509: false
        }
    }
}

/// Reads what `gh auth status` prints: each host on a line of its own, then
/// for each account on it, whether gh is signed in, whether it's the host's
/// active account, and its token's scopes.
///
/// ```
/// github.com
///   ✓ Logged in to github.com account sam (keyring)
///   - Active account: true
///   - Git operations protocol: https
///   - Token: gho_************************************
///   - Token scopes: 'gist', 'read:org', 'repo', 'workflow'
/// ```
public enum GitHubAuthStatusParser {
    public static let arguments = ["auth", "status"]

    /// The active account of each host gh is signed in to. An account that
    /// failed to sign in isn't one.
    public static func parse(_ text: String) -> [GitHubAccount] {
        var accounts: [GitHubAccount] = []
        var host: String?
        var current: (host: String, isActive: Bool?, scopes: Set<String>)?

        func finish() {
            if let account = current, account.isActive != false {
                accounts.append(GitHubAccount(host: account.host, scopes: account.scopes))
            }
            current = nil
        }

        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if !line.hasPrefix(" "), !line.hasPrefix("\t") {
                finish()
                host = trimmed
                continue
            }
            if let range = trimmed.range(of: "Logged in to ") {
                finish()
                let rest = trimmed[range.upperBound...]
                let named = rest.split(separator: " ").first.map(String.init)
                guard let accountHost = named ?? host else { continue }
                current = (accountHost.lowercased(), nil, [])
            } else if trimmed.contains("Failed to log in") || trimmed.contains("Failed to authenticate") {
                finish()
            } else if let value = value(of: "Active account:", in: trimmed) {
                current?.isActive = value.lowercased() == "true"
            } else if let value = value(of: "Token scopes:", in: trimmed) {
                current?.scopes = Set(value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                }.filter { !$0.isEmpty && $0 != "none" })
            }
        }
        finish()
        return accounts
    }

    private static func value(of label: String, in line: String) -> String? {
        guard let range = line.range(of: label) else { return nil }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }
}

/// Reads what `gpg --status-fd 1` says once it has made a key.
public enum OpenPGPStatusParser {
    /// The new key's fingerprint, from a line such as
    /// `[GNUPG:] KEY_CREATED P 4B5A…`, where P is a primary key and B is a
    /// primary key with a subkey.
    public static func createdKey(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ")
            guard words.count >= 4, words[0] == "[GNUPG:]", words[1] == "KEY_CREATED" else { continue }
            return String(words[3]).uppercased()
        }
        return nil
    }
}

/// Reads the versions that setup's Look Around shows for the programs
/// commits are signed with, and for gh.
public enum ProgramVersionParser {
    /// `gpg --version` starts with `gpg (GnuPG) 2.4.7`.
    public static func gpg(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isNewline).first, first.contains("GnuPG") else { return nil }
        return first.split(separator: " ").last.map(String.init)
    }

    /// `ssh -V` prints `OpenSSH_9.9p2, LibreSSL 3.3.6`, which reads as
    /// OpenSSH 9.9p2.
    public static func openSSH(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isNewline).first, first.hasPrefix("OpenSSH_") else { return nil }
        let name = first.split(separator: ",").first.map(String.init) ?? String(first)
        return name.replacingOccurrences(of: "_", with: " ")
    }

    /// `gh --version` starts with `gh version 2.105.0 (2026-11-17)`.
    public static func gh(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isNewline).first, first.hasPrefix("gh version ") else { return nil }
        return first.dropFirst("gh version ".count).split(separator: " ").first.map(String.init)
    }
}
