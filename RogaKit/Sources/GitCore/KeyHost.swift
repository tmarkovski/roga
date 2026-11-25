import Foundation

/// A host where someone adds the public half of a signing key, so that the
/// commits it signs show as verified there (decision 108): GitHub, with the
/// GitHub Enterprise hosts that gh is signed in to, and GitLab.
public enum KeyHost: Sendable, Hashable, Identifiable {
    case gitHub(String)
    case gitLab(String)

    public var id: String { "\(name) \(host)" }

    public var host: String {
        switch self {
        case .gitHub(let host), .gitLab(let host): host
        }
    }

    /// What people call it.
    public var name: String {
        switch self {
        case .gitHub: "GitHub"
        case .gitLab: "GitLab"
        }
    }

    /// The page for adding a key of a format to the signed-in account, or
    /// nil for X.509, whose certificates neither host takes.
    public func page(for format: CommitIdentity.SigningFormat) -> URL? {
        switch (self, format) {
        case (.gitHub(let host), .ssh): URL(string: "https://\(host)/settings/ssh/new")
        case (.gitHub(let host), .openPGP): URL(string: "https://\(host)/settings/gpg/new")
        case (.gitLab(let host), .ssh): URL(string: "https://\(host)/-/user_settings/ssh_keys")
        case (.gitLab(let host), .openPGP): URL(string: "https://\(host)/-/user_settings/gpg_keys")
        case (_, .x509): nil
        }
    }

    /// The hosts that a repository's remotes are on, `origin`'s first, then
    /// the others by the names of their remotes, each host once. A remote on
    /// a host that isn't GitHub or GitLab has none.
    ///
    /// - Parameters:
    ///   - remoteURLs: Each remote's URL, by the remote's name.
    ///   - gitHubCLIHosts: The hosts gh is signed in to, which makes a GitHub
    ///     Enterprise host count as GitHub.
    public static func hosts(remoteURLs: [String: String], gitHubCLIHosts: Set<String> = []) -> [KeyHost] {
        let names = (remoteURLs["origin"] == nil ? [] : ["origin"]) + remoteURLs.keys.filter { $0 != "origin" }.sorted()
        var seen: Set<KeyHost> = []
        return names
            .compactMap { remoteURLs[$0].flatMap(RemoteAddress.host).flatMap { of(host: $0, gitHubCLIHosts: gitHubCLIHosts) } }
            .filter { seen.insert($0).inserted }
    }

    /// The host a remote's host stands for, or nil when it isn't one where
    /// Roga knows how to add a key.
    public static func of(host: String, gitHubCLIHosts: Set<String> = []) -> KeyHost? {
        let host = host.lowercased()
        // GitHub's and GitLab's SSH over port 443 go to the same accounts.
        if ["github.com", "www.github.com", "ssh.github.com"].contains(host) { return .gitHub("github.com") }
        if gitHubCLIHosts.contains(host) { return .gitHub(host) }
        if ["gitlab.com", "www.gitlab.com", "altssh.gitlab.com"].contains(host) { return .gitLab("gitlab.com") }
        if host.hasPrefix("gitlab.") { return .gitLab(host) }
        return nil
    }
}

extension RemoteAddress {
    /// The host of a remote's URL, in lowercase, without a user or a port,
    /// as in `github.com` for `git@github.com:torvalds/linux.git`, or nil
    /// for a local path.
    public static func host(_ url: String) -> String? {
        if let scheme = url.firstRange(of: "://") {
            guard url[..<scheme.lowerBound].lowercased() != "file" else { return nil }
        } else {
            // A slash before the colon makes it a local path, as in `shown(_:)`.
            guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
        }
        let shown = shown(url)
        let authority = shown.split(separator: "/", maxSplits: 1).first.map(String.init) ?? shown
        let host = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? authority
        return host.isEmpty ? nil : host.lowercased()
    }
}
