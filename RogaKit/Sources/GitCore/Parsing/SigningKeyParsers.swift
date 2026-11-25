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
        return key(type: String(parts[0]), blob: data, comment: parts.count > 2 ? String(parts[2]) : "")
    }

    /// A key from its type and its bytes, with the fingerprint `ssh-keygen
    /// -l` prints: `SHA256:` and the bytes' hash in base64, without padding.
    static func key(type: String, blob: Data, comment: String) -> SSHPublicKey {
        let hash = Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return SSHPublicKey(
            type: type,
            blob: blob.base64EncodedString(),
            comment: comment.trimmingCharacters(in: .whitespacesAndNewlines),
            fingerprint: "SHA256:" + hash
        )
    }
}

/// Reads which key made a commit's SSH signature, from the signature itself
/// (issue 119), since git says which key signed a commit only once it can
/// check it against `gpg.ssh.allowedSignersFile`.
public enum SSHSignatureParser {
    /// The signature in the headers that `git cat-file commit` prints:
    /// `gpgsig`, or `gpgsig-sha256` in a SHA-256 repository, whose lines
    /// after the first start with a space.
    public static func signature(inCommit text: String) -> String? {
        var lines: [Substring] = []
        var isInSignature = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // A blank line ends the headers.
            if line.isEmpty { break }
            if isInSignature {
                guard line.hasPrefix(" ") else { break }
                lines.append(line.dropFirst())
            } else if line.hasPrefix("gpgsig ") || line.hasPrefix("gpgsig-sha256 ") {
                isInSignature = true
                lines.append(line[line.index(after: line.firstIndex(of: " ")!)...])
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The public key in an armored SSH signature, which OpenSSH's
    /// PROTOCOL.sshsig lays out as `SSHSIG`, a version, then the key.
    public static func publicKey(inSignature armored: String) -> SSHPublicKey? {
        guard armored.contains("-----BEGIN SSH SIGNATURE-----") else { return nil }
        let base64 = armored.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: base64) else { return nil }
        var reader = Reader(bytes: [UInt8](data))
        guard reader.take(6) == Array("SSHSIG".utf8), reader.uint32() != nil,
              let blob = reader.string()
        else { return nil }
        var inner = Reader(bytes: blob)
        guard let type = inner.string().map({ String(decoding: $0, as: UTF8.self) }),
              SSHPublicKeyParser.typeNames[type] != nil
        else { return nil }
        return SSHPublicKeyParser.key(type: type, blob: Data(blob), comment: "")
    }

    /// Reads the SSH wire format: 32-bit lengths, big-endian, before bytes.
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }

        mutating func uint32() -> UInt32? {
            take(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
        }

        mutating func string() -> [UInt8]? {
            uint32().flatMap { take(Int($0)) }
        }
    }
}

/// Reads which key made an OpenPGP signature, from the signature itself,
/// so that the commit panel can name the key before gpg checks it (decision
/// 109). It reads the signature packet's issuer, which RFC 9580 lays out.
public enum OpenPGPSignatureParser {
    /// The key ID that git's `%GK` prints once gpg has checked the
    /// signature: the 16 hex digits of the key that made it, from the
    /// issuer subpacket, or else from the issuer's fingerprint.
    public static func keyID(inSignature armored: String) -> String? {
        guard armored.contains("-----BEGIN PGP SIGNATURE-----"),
              let bytes = dearmored(armored),
              let body = signaturePacket(in: bytes)
        else { return nil }
        return keyID(inSignatureBody: body).map(hex)
    }

    /// The bytes between the armor's lines, without its headers, such as
    /// `Version:`, and its checksum, which starts with `=`.
    static func dearmored(_ armored: String) -> [UInt8]? {
        let lines = armored.split(whereSeparator: \.isNewline)
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN") }),
              let end = lines.lastIndex(where: { $0.hasPrefix("-----END") }), begin < end
        else { return nil }
        let base64 = lines[(begin + 1)..<end]
            .filter { !$0.isEmpty && !$0.hasPrefix("=") && !$0.contains(":") }
            .joined()
        return Data(base64Encoded: base64).map { [UInt8]($0) }
    }

    /// The body of the first packet when it's a signature, whose tag is 2,
    /// with either the old or the new packet header.
    static func signaturePacket(in bytes: [UInt8]) -> ArraySlice<UInt8>? {
        guard let first = bytes.first, first & 0x80 != 0 else { return nil }
        let tag: UInt8
        var start = 0
        var length: Int?
        if first & 0x40 != 0 {
            tag = first & 0x3F
            guard bytes.count > 1 else { return nil }
            let octet = Int(bytes[1])
            switch octet {
            case ..<192:
                (start, length) = (2, octet)
            case 192..<224:
                guard bytes.count > 2 else { return nil }
                (start, length) = (3, ((octet - 192) << 8) + Int(bytes[2]) + 192)
            case 255:
                guard bytes.count > 5 else { return nil }
                (start, length) = (6, bytes[2..<6].reduce(0) { $0 << 8 | Int($1) })
            default:
                // A partial length: the rest is enough to find the issuer.
                start = 2
            }
        } else {
            tag = (first >> 2) & 0x0F
            switch first & 0x03 {
            case 0:
                guard bytes.count > 1 else { return nil }
                (start, length) = (2, Int(bytes[1]))
            case 1:
                guard bytes.count > 2 else { return nil }
                (start, length) = (3, Int(bytes[1]) << 8 | Int(bytes[2]))
            case 2:
                guard bytes.count > 4 else { return nil }
                (start, length) = (5, bytes[1..<5].reduce(0) { $0 << 8 | Int($1) })
            default:
                start = 1
            }
        }
        guard tag == 2, start < bytes.count else { return nil }
        let end = length.map { min(start + $0, bytes.count) } ?? bytes.count
        return bytes[start..<end]
    }

    /// The issuer's key ID in a signature packet's body. A version 3
    /// signature has it in a field of its own, and later versions in a
    /// subpacket: the issuer, 16, or the issuer's fingerprint, 33.
    static func keyID(inSignatureBody body: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        var reader = Reader(bytes: body)
        guard let version = reader.byte() else { return nil }
        switch version {
        case 3:
            // The length of what's hashed, which is 5, the type and the time.
            guard reader.take(6) != nil else { return nil }
            return reader.take(8)
        case 4, 5, 6:
            // The type, the public key's algorithm and the hash's.
            guard reader.take(3) != nil else { return nil }
            let lengthSize = version == 4 ? 2 : 4
            var subpackets: [ArraySlice<UInt8>] = []
            for _ in 0..<2 {
                guard let count = reader.number(lengthSize), let area = reader.take(count) else { break }
                subpackets.append(area)
            }
            var fingerprint: ArraySlice<UInt8>?
            for area in subpackets {
                for (type, value) in self.subpackets(in: area) {
                    if type == 16, value.count == 8 { return value }
                    if type == 33, fingerprint == nil, let keyVersion = value.first {
                        // A version 4 key's ID ends its fingerprint, and a
                        // later key's starts it.
                        let digits = value.dropFirst()
                        fingerprint = keyVersion == 4 ? digits.suffix(8) : digits.prefix(8)
                    }
                }
            }
            return fingerprint.flatMap { $0.count == 8 ? $0 : nil }
        default:
            return nil
        }
    }

    /// Each subpacket's type, without the bit that marks it critical, and
    /// its value.
    static func subpackets(in area: ArraySlice<UInt8>) -> [(type: UInt8, value: ArraySlice<UInt8>)] {
        var found: [(UInt8, ArraySlice<UInt8>)] = []
        var reader = Reader(bytes: area)
        while let octet = reader.byte().map(Int.init) {
            let length: Int
            switch octet {
            case ..<192: length = octet
            case 192..<255:
                guard let next = reader.byte() else { return found }
                length = ((octet - 192) << 8) + Int(next) + 192
            default:
                guard let number = reader.number(4) else { return found }
                length = number
            }
            guard length >= 1, let type = reader.byte(), let value = reader.take(length - 1) else { return found }
            found.append((type & 0x7F, value))
        }
        return found
    }

    private static func hex(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// Reads big-endian numbers and runs of bytes.
    private struct Reader {
        let bytes: ArraySlice<UInt8>
        var offset: Int

        init(bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
            offset = bytes.startIndex
        }

        mutating func byte() -> UInt8? {
            take(1)?.first
        }

        mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, offset + count <= bytes.endIndex else { return nil }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }

        mutating func number(_ size: Int) -> Int? {
            take(size).map { $0.reduce(0) { $0 << 8 | Int($1) } }
        }
    }
}

/// Which key made a commit's signature, read from the commit's own
/// `gpgsig` header without checking it (decision 109).
public enum CommitSignatureParser {
    /// The key as git's `%GK` names it once the signature is checked: an
    /// SSH key's `SHA256:` fingerprint, or an OpenPGP key's ID. An X.509
    /// signature's certificate isn't read.
    ///
    /// - Parameter text: What `git cat-file commit` printed.
    public static func key(inCommit text: String) -> String? {
        guard let signature = SSHSignatureParser.signature(inCommit: text) else { return nil }
        if let key = SSHSignatureParser.publicKey(inSignature: signature) { return key.fingerprint }
        return OpenPGPSignatureParser.keyID(inSignature: signature)
    }
}

/// The file `gpg.ssh.allowedSignersFile` names, which says whose SSH keys git
/// trusts when it checks a signature (issue 119). Each line has the emails
/// the key signs for, optional options such as `namespaces="git"`, then the
/// key.
public enum AllowedSignersFile {
    /// The line that trusts a key for an email's git signatures.
    public static func line(email: String, key: SSHPublicKey) -> String {
        "\(email) namespaces=\"git\" \(key.type) \(key.blob)"
    }

    /// Whether a line in the file already lists the key for the email,
    /// comparing emails without case.
    public static func lists(_ key: SSHPublicKey, for email: String, in text: String) -> Bool {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = self.words(line)
            guard let principals = words.first, !principals.hasPrefix("#"),
                  let type = words.firstIndex(where: { SSHPublicKeyParser.typeNames[$0] != nil }),
                  type + 1 < words.count, words[type + 1] == key.blob
            else { continue }
            let emails = principals.split(separator: ",").map { $0.lowercased() }
            if emails.contains(email.lowercased()) { return true }
        }
        return false
    }

    /// A line's words, split by spaces outside double quotes, without the
    /// quotes around a whole word.
    static func words(_ line: Substring) -> [String] {
        var words: [String] = []
        var word = ""
        var isQuoted = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if character == "\"" {
                isQuoted.toggle()
                word.append(character)
            } else if character == " " || character == "\t", !isQuoted {
                if !word.isEmpty { words.append(word) }
                word = ""
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { words.append(word) }
        return words.map { $0.hasPrefix("\"") && $0.hasSuffix("\"") && $0.count >= 2 ? String($0.dropFirst().dropLast()) : $0 }
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
