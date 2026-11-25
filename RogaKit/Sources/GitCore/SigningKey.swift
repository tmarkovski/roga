import Foundation

/// A key on this Mac that can sign commits, which the identity's Key field
/// offers (decision 106). Roga finds them with the programs git signs with,
/// `ssh-keygen` and `ssh-add` for SSH and `gpg` for OpenPGP, and keeps
/// nothing about them.
public struct SigningKey: Sendable, Hashable, Identifiable {
    /// What `user.signingkey` gets when the key is chosen: a `.pub` file's
    /// path, a public key that's only in an agent as `key::ssh-ed25519 AAAA…`,
    /// or an OpenPGP key's fingerprint.
    public var value: String
    /// What the list calls it: the file's path, an agent's key's comment, or
    /// an OpenPGP key's first user ID.
    public var title: String
    /// What else tells it apart, such as its type and where it is, as in
    /// `ED25519 · sam@laptop` or `ED25519 · on a smartcard`.
    public var details: [String]
    /// `SHA256:…` for an SSH key, or an OpenPGP key's fingerprint.
    public var fingerprint: String
    /// The emails the key names, in its comment or its user IDs, which put
    /// it first when one is the identity's.
    public var emails: [String]

    public var id: String { value }

    public init(value: String, title: String, details: [String], fingerprint: String, emails: [String]) {
        self.value = value
        self.title = title
        self.details = details
        self.fingerprint = fingerprint
        self.emails = emails
    }

    /// The details on one line.
    public var subtitle: String {
        details.joined(separator: " · ")
    }

    /// Whether the key names this email, without case, as hosting sites
    /// match emails.
    public func names(_ email: String?) -> Bool {
        guard let email = email?.lowercased(), !email.isEmpty else { return false }
        return emails.contains { $0.lowercased() == email }
    }
}

/// The emails in a key's comment or user ID, such as `sam@rivera.dev` in
/// `Sam Rivera <sam@rivera.dev>` or in `sam@rivera.dev`.
public enum KeyEmails {
    public static func find(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || "<>(),;\"'".contains($0) })
            .map(String.init)
            .filter { word in
                guard let at = word.firstIndex(of: "@"), at != word.startIndex else { return false }
                let domain = word[word.index(after: at)...]
                return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
            }
    }
}
