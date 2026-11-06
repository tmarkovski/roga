/// An agent's release number, as its command-line tool prints it with
/// `--version` (decision 41).
///
/// Versions are compared the way semantic versioning orders them, so a
/// prerelease such as the ChatGPT app's `0.166.0-alpha.6` comes before the
/// release it leads up to. Build metadata after a `+` is dropped, since it
/// doesn't take part in the order.
public struct AgentVersion: Comparable, Sendable, Hashable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// What follows the `-`, such as `alpha.6`, or nil for a release.
    public var prerelease: String?

    public init(major: Int, minor: Int, patch: Int = 0, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Reads the first version number in what `--version` printed, such as
    /// `2.1.286 (Claude Code)`, `codex-cli 0.166.0-alpha.6` or
    /// `codex-cli 0.166.0`. A word counts when it has at least a major and a
    /// minor number, so a stray number in a warning before it isn't taken for
    /// one.
    public init?(versionOutput: String) {
        for word in versionOutput.split(whereSeparator: \.isWhitespace) {
            if let version = AgentVersion(word: word) {
                self = version
                return
            }
        }
        return nil
    }

    private init?(word: Substring) {
        var text = word.trimmingPrefix { "([{\"'".contains($0) }
        while let last = text.last, ")]},;:\"'".contains(last) {
            text = text.dropLast()
        }
        if text.first == "v" { text = text.dropFirst() }
        if let plus = text.firstIndex(of: "+") { text = text[..<plus] }

        var prerelease: String?
        if let dash = text.firstIndex(of: "-") {
            let rest = text[text.index(after: dash)...]
            guard !rest.isEmpty, rest.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
                return nil
            }
            prerelease = String(rest)
            text = text[..<dash]
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers.count > 2 ? numbers[2] : 0, prerelease: prerelease)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: AgentVersion, rhs: AgentVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let left?, let right?): return precedes(left, right)
        }
    }

    /// Semantic versioning's order for prereleases: dot-separated parts are
    /// compared in turn, numbers by value and before any word, words by their
    /// characters, and a shorter list first when one starts the other.
    private static func precedes(_ left: String, _ right: String) -> Bool {
        let leftParts = left.split(separator: ".", omittingEmptySubsequences: false)
        let rightParts = right.split(separator: ".", omittingEmptySubsequences: false)
        for (l, r) in zip(leftParts, rightParts) where l != r {
            switch (Int(l), Int(r)) {
            case (let a?, let b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return Array(l.utf8).lexicographicallyPrecedes(Array(r.utf8))
            }
        }
        return leftParts.count < rightParts.count
    }
}
