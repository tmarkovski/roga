/// What git found when it checked a commit's signature, with
/// `git log --format=%G?` (decision 104). Checking runs gpg or ssh-keygen, so
/// Roga checks only the commit the panels show.
public struct SignatureCheck: Sendable, Hashable {
    public enum Result: Sendable, Hashable {
        /// `G`: the signature is good, and the key is one this Mac trusts.
        case good
        /// `U`: the signature is good, but the key isn't one this Mac
        /// trusts, such as an SSH key that the allowed signers file doesn't
        /// list.
        case untrusted
        /// `X` or `Y`: the signature was good, but it or its key has expired.
        case expired
        /// `R`: the signature was made with a key that has been revoked.
        case revoked
        /// `B`: the signature doesn't match the commit.
        case bad
        /// `E`: git couldn't check it, usually because this Mac doesn't have
        /// the key.
        case missingKey
        /// `N` for a commit that has a signature: git didn't check it, as
        /// for an SSH signature without `gpg.ssh.allowedSignersFile`, or with
        /// no program to check it.
        case notChecked
    }

    public var result: Result
    /// Who signed it, as gpg names them or the allowed signers file does.
    public var signer: String?
    /// The key that signed it.
    public var key: String?

    public init(result: Result, signer: String? = nil, key: String? = nil) {
        self.result = result
        self.signer = signer
        self.key = key
    }
}

/// The key that made a commit's signature, read from the commit itself
/// without checking it (decisions 109 and 117).
public struct SignatureKey: Sendable, Hashable {
    /// The key as git's `%GK` names it once it has checked: an SSH key's
    /// `SHA256:` fingerprint, or an OpenPGP key's ID.
    public var id: String
    /// An SSH key's public half, which an SSH signature carries. An OpenPGP
    /// signature only names its key, so its public half comes from gpg.
    public var ssh: SSHPublicKey?

    public init(id: String, ssh: SSHPublicKey? = nil) {
        self.id = id
        self.ssh = ssh
    }
}

/// Reads `git log --format=%G?%x00%GS%x00%GK` for one commit.
public enum SignatureCheckParser {
    /// The commit's own line, without the signature that `log.showSignature`
    /// would add above it.
    public static func arguments(_ commit: ObjectID) -> [String] {
        ["log", "-1", "--no-show-signature", "--format=%G?%x00%GS%x00%GK", commit.hex]
    }

    public static func parse(_ output: [UInt8]) throws(ParseError) -> SignatureCheck {
        var text = output
        while text.last == UInt8(ascii: "\n") { text.removeLast() }
        let fields = text.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard fields.count == 3 else {
            throw ParseError("git log printed \(fields.count) fields when asked about a signature, rather than 3.")
        }
        let result: SignatureCheck.Result
        switch fields[0] {
        case "G": result = .good
        case "U": result = .untrusted
        case "X", "Y": result = .expired
        case "R": result = .revoked
        case "B": result = .bad
        case "E": result = .missingKey
        case "N": result = .notChecked
        default: throw ParseError("git log printed \(fields[0]) for a signature, which isn't one of its letters.")
        }
        return SignatureCheck(result: result, signer: fields[1].isEmpty ? nil : fields[1], key: fields[2].isEmpty ? nil : fields[2])
    }
}
