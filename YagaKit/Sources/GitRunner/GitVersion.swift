/// A git release number, as `git version` prints it.
public struct GitVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    /// The oldest git that yaga supports (decision 8).
    public static let minimumSupported = GitVersion(major: 2, minor: 44, patch: 0)

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads the version from the output of `git version`. Builds add their
    /// own suffixes, as in `git version 2.50.1 (Apple Git-155)`,
    /// `git version 2.53.0.rc1` and `git version 2.52.0.290.g1a2b3c4`, and
    /// only the first three numbers are kept.
    public init?(versionOutput: some StringProtocol) {
        let prefix = "git version "
        guard versionOutput.hasPrefix(prefix) else { return nil }
        let release = versionOutput.dropFirst(prefix.count).prefix { !$0.isWhitespace }
        var numbers: [Int] = []
        for part in release.split(separator: ".", omittingEmptySubsequences: false).prefix(3) {
            guard let number = Int(part), number >= 0 else { break }
            numbers.append(number)
        }
        guard numbers.count >= 2 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers.count > 2 ? numbers[2] : 0)
    }

    public var isSupported: Bool { self >= Self.minimumSupported }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
