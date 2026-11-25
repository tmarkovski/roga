import CryptoKit
import Foundation

/// An SSH public key, as a `.pub` file or `ssh-add -L` has it on one line.
public struct SSHPublicKey: Sendable, Hashable {
    /// Its algorithm's name, as in `ssh-ed25519`.
    public var type: String
    /// The key itself, in base64.
    public var blob: String
    /// What follows the key, often who it's for, as in `sam@laptop`.
    public var comment: String
    /// `SHA256:` and the key's hash, as `ssh-keygen -l` prints it.
    public var fingerprint: String

    /// The key as git takes it in `user.signingkey`, when it isn't in a file.
    public var literal: String {
        "key::\(type) \(blob)" + (comment.isEmpty ? "" : " \(comment)")
    }

    /// The algorithm as `ssh-keygen -l` names it, as in `ED25519`.
    public var typeName: String {
        SSHPublicKeyParser.typeNames[type] ?? type
    }

    /// Whether it's a security key's, which asks for a touch for every
    /// signature.
    public var isSecurityKey: Bool {
        type.hasPrefix("sk-")
    }
}

/// Reads SSH public keys from `.pub` files and from `ssh-add -L` (decision
/// 106).
public enum SSHPublicKeyParser {
    /// The algorithms `ssh-keygen -Y sign` signs with, and what `ssh-keygen
    /// -l` calls them. Certificates aren't here, so they're left out.
    static let typeNames = [
        "ssh-ed25519": "ED25519",
        "ssh-rsa": "RSA",
        "ecdsa-sha2-nistp256": "ECDSA",
        "ecdsa-sha2-nistp384": "ECDSA",
        "ecdsa-sha2-nistp521": "ECDSA",
        "sk-ssh-ed25519@openssh.com": "ED25519-SK",
        "sk-ecdsa-sha2-nistp256@openssh.com": "ECDSA-SK",
    ]

    /// Every key in the text, one to a line, leaving out lines that aren't
    /// a key, such as `ssh-add`'s "The agent has no identities."
    public static func parseLines(_ text: String) -> [SSHPublicKey] {
        text.split(whereSeparator: \.isNewline).compactMap(parse)
    }

    /// The key on a line: its type, its base64 and an optional comment.
    public static func parse<Line: StringProtocol>(_ line: Line) -> SSHPublicKey? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, typeNames[String(parts[0])] != nil,
              let data = Data(base64Encoded: String(parts[1])), !data.isEmpty
        else { return nil }
        let hash = Data(SHA256.hash(data: data)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return SSHPublicKey(
            type: String(parts[0]),
            blob: String(parts[1]),
            comment: parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines) : "",
            fingerprint: "SHA256:" + hash
        )
    }
}

/// Finds the agent that `~/.ssh/config` sends SSH to with `IdentityAgent`,
/// as 1Password's setup does, since `ssh-add` doesn't read that file.
public enum SSHConfigParser {
    /// The socket the first `IdentityAgent` names, with `~` expanded, or nil
    /// when none does. It doesn't look at which hosts the line is for: an
    /// agent set up for some hosts can still sign.
    public static func identityAgent(in text: String, home: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            // A keyword and its value are split by spaces or by `=`.
            guard let split = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { continue }
            guard trimmed[..<split].lowercased() == "identityagent" else { continue }
            var value = trimmed[trimmed.index(after: split)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            // These mean the usual agent, or none.
            guard !value.isEmpty, value != "none", value != "SSH_AUTH_SOCK" else { continue }
            if value == "~" { return home }
            if value.hasPrefix("~/") { return home + value.dropFirst() }
            return value
        }
        return nil
    }
}

/// An OpenPGP key that can sign, from `gpg --list-secret-keys`.
public struct OpenPGPSecretKey: Sendable, Hashable {
    /// The primary key's fingerprint, which `user.signingkey` gets.
    public var fingerprint: String
    /// Its user IDs, as in `Sam Rivera <sam@rivera.dev>`.
    public var userIDs: [String]
    /// The signing key's algorithm, as in `ED25519` or `RSA 4096`.
    public var algorithm: String
    /// Whether the key that signs is on a smartcard, such as a YubiKey.
    public var isOnCard: Bool

    /// The last 16 digits of the fingerprint, which gpg calls the long key ID.
    public var keyID: String {
        String(fingerprint.suffix(16))
    }
}

/// Reads `gpg --list-secret-keys --with-colons` (decision 106).
public enum OpenPGPKeyParser {
    /// Lists the secret keys in gpg's colon format, with dates as seconds,
    /// and without asking anything.
    public static let arguments = ["--batch", "--with-colons", "--fixed-list-mode", "--list-secret-keys"]

    /// One record of gpg's colon format, by its 1-based field numbers.
    private struct Record {
        let fields: [Substring]

        subscript(_ number: Int) -> String {
            number - 1 < fields.count ? String(fields[number - 1]) : ""
        }
    }

    /// The keys that can sign now: left out are keys that have expired, were
    /// revoked or are disabled, and keys with no part that signs whose secret
    /// is here or on a card.
    public static func parse(_ text: String, now: Date = Date()) -> [OpenPGPSecretKey] {
        var keys: [OpenPGPSecretKey] = []
        var primary: Record?
        var fingerprint: String?
        var userIDs: [String] = []
        // The parts that sign, the primary key or a subkey, with what
        // follows them.
        var signers: [Record] = []
        var lastWasKey = false

        func finish() {
            defer {
                primary = nil
                fingerprint = nil
                userIDs = []
                signers = []
            }
            guard let primary, let fingerprint else { return }
            // The whole key's abilities are in uppercase; D means disabled.
            let abilities = primary[12]
            guard abilities.contains("S"), !abilities.contains("D"), isUsable(primary, now: now) else { return }
            let usable = signers.filter { isUsable($0, now: now) && hasSecret($0) }
            guard let signer = usable.first(where: { isOnCard($0) }) ?? usable.first else { return }
            keys.append(OpenPGPSecretKey(
                fingerprint: fingerprint,
                userIDs: userIDs,
                algorithm: algorithm(signer),
                isOnCard: isOnCard(signer)
            ))
        }

        for line in text.split(whereSeparator: \.isNewline) {
            let record = Record(fields: line.split(separator: ":", omittingEmptySubsequences: false))
            switch record[1] {
            case "sec":
                finish()
                primary = record
                if record[12].contains("s") { signers.append(record) }
                lastWasKey = true
            case "ssb":
                if record[12].contains("s") { signers.append(record) }
                lastWasKey = false
            case "fpr":
                // The first fingerprint after `sec` is the primary key's.
                if lastWasKey, fingerprint == nil { fingerprint = record[10] }
                lastWasKey = false
            case "uid":
                if !["r", "e", "i", "d"].contains(record[2]) { userIDs.append(unescape(record[10])) }
                lastWasKey = false
            default:
                break
            }
        }
        finish()
        return keys
    }

    /// Whether a key or subkey hasn't expired, been revoked or been disabled.
    private static func isUsable(_ record: Record, now: Date) -> Bool {
        guard !["e", "r", "i", "d", "n"].contains(record[2]) else { return false }
        if let expires = TimeInterval(record[7]), expires > 0, Date(timeIntervalSince1970: expires) <= now { return false }
        return true
    }

    /// Whether its secret is here or on a card. `#` says only a stub is here.
    private static func hasSecret(_ record: Record) -> Bool {
        record[15] != "#"
    }

    /// Whether its secret is on a card, which gpg says with the card's serial
    /// number in place of `+`.
    private static func isOnCard(_ record: Record) -> Bool {
        let serial = record[15]
        return !serial.isEmpty && serial != "+" && serial != "#"
    }

    /// The algorithm's name: the curve for elliptic keys, or the algorithm
    /// and its length.
    private static func algorithm(_ record: Record) -> String {
        let curve = record[17]
        if !curve.isEmpty { return curve.uppercased() }
        switch record[4] {
        case "1", "2", "3": return "RSA \(record[3])"
        case "17": return "DSA \(record[3])"
        case "19": return "ECDSA"
        case "22": return "EdDSA"
        default: return "Algorithm \(record[4])"
        }
    }

    /// A user ID as gpg escapes it in the colon format, where `\x3a` is a
    /// colon.
    static func unescape(_ text: String) -> String {
        guard text.contains("\\x") else { return text }
        var bytes: [UInt8] = []
        var index = text.utf8.startIndex
        let utf8 = text.utf8
        while index < utf8.endIndex {
            let byte = utf8[index]
            if byte == UInt8(ascii: "\\"),
               let x = utf8.index(index, offsetBy: 1, limitedBy: utf8.endIndex), x < utf8.endIndex, utf8[x] == UInt8(ascii: "x"),
               let end = utf8.index(x, offsetBy: 3, limitedBy: utf8.endIndex),
               let value = UInt8(String(decoding: utf8[utf8.index(after: x)..<end], as: UTF8.self), radix: 16)
            {
                bytes.append(value)
                index = end
            } else {
                bytes.append(byte)
                index = utf8.index(after: index)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
