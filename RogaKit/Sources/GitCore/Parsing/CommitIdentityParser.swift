/// Reads who a repository's commits go out as from `git config`, with where
/// each setting comes from (decision 103).
public enum CommitIdentityParser {
    /// Only the settings for who commits are from and how they're signed.
    /// git matches the pattern against each key with its section and name in
    /// lowercase. It exits with status 1 when none is set.
    public static let arguments = [
        "config", "-z", "--show-scope", "--show-origin", "--get-regexp",
        #"^(user\.(name|email|signingkey)|commit\.gpgsign|gpg\.format|gpg\.ssh\.defaultkeycommand)$"#,
    ]

    /// Each setting is three fields, each ending in a NUL byte: its scope, its
    /// origin, such as `file:/Users/sam/.gitconfig` or `command line:`, and its
    /// key, then a line break and its value. A key with no `=` has no line
    /// break. git prints the settings in the order it reads them, so a later
    /// one is the one that counts.
    public static func parse(_ output: [UInt8]) throws(ParseError) -> CommitIdentity {
        var fields = output.split(separator: 0, omittingEmptySubsequences: false)
        // The last field ends in a NUL byte too.
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count % 3 == 0 else {
            throw ParseError("git config printed \(fields.count) fields, which isn't a whole number of settings.")
        }
        var identity = CommitIdentity()
        for start in stride(from: 0, to: fields.count, by: 3) {
            let scope = String(decoding: fields[start], as: UTF8.self)
            let origin = try origin(String(decoding: fields[start + 1], as: UTF8.self), scope: scope)
            let entry = fields[start + 2]
            let key: String
            let value: String?
            if let lineBreak = entry.firstIndex(of: UInt8(ascii: "\n")) {
                key = String(decoding: entry[..<lineBreak], as: UTF8.self)
                value = String(decoding: entry[entry.index(after: lineBreak)...], as: UTF8.self)
            } else {
                key = String(decoding: entry, as: UTF8.self)
                value = nil
            }
            let setting = CommitIdentity.Setting(value, origin: origin)
            switch key {
            case "user.name": identity.name = setting
            case "user.email": identity.email = setting
            case "user.signingkey": identity.signingKey = setting
            case "commit.gpgsign": identity.signsCommits = setting
            case "gpg.format": identity.signingFormat = setting
            case "gpg.ssh.defaultkeycommand": identity.defaultKeyCommand = setting
            default:
                throw ParseError("git config printed \(key) when asked who commits are from.")
            }
        }
        return identity
    }

    private static func origin(_ text: String, scope: String) throws(ParseError) -> ConfigOrigin {
        guard let colon = text.firstIndex(of: ":") else {
            throw ParseError("git config printed \(text) where it says where a setting comes from.")
        }
        let kind = text[..<colon]
        let rest = String(text[text.index(after: colon)...])
        return ConfigOrigin(
            scope: ConfigOrigin.Scope(rawValue: scope) ?? .unknown,
            file: kind == "file" && !rest.isEmpty ? rest : nil
        )
    }
}
