import Foundation
import GitCore
import GitRunner
import SystemConfiguration

/// Where a new key's public half can go so that the commits it signs show
/// as verified, and whether gh can put it there (decision 108). It's looked
/// up once a key is made, not in setup, so that a gh signed in or given a
/// scope since then counts.
public struct KeyHosting: Sendable, Hashable {
    /// gh's path, or nil when it isn't on this Mac.
    public var gh: String?
    /// The accounts gh is signed in to.
    public var accounts: [GitHubAccount]
    /// The hosts to offer: those the repository's remotes are on, or, in
    /// Settings, which has no repository, those gh is signed in to.
    public var hosts: [KeyHost]

    public init(gh: String?, accounts: [GitHubAccount], hosts: [KeyHost]) {
        self.gh = gh
        self.accounts = accounts
        self.hosts = hosts
    }

    /// The account gh is signed in to on a GitHub host, or nil.
    public func account(on host: KeyHost) -> GitHubAccount? {
        guard case .gitHub(let name) = host else { return nil }
        return accounts.first { $0.host == name }
    }

    /// Whether gh can add a key of the format to the host now.
    public func canAdd(_ format: CommitIdentity.SigningFormat, to host: KeyHost) -> Bool {
        gh != nil && account(on: host)?.canAdd(format) == true
    }

    /// Looks for gh and the accounts it's signed in to, which asks the
    /// hosts whether its tokens still work.
    ///
    /// - Parameter remoteURLs: The repository's remotes, by name, or nil in
    ///   Settings.
    @concurrent
    public static func look(remoteURLs: [String: String]?, programs: Programs) async -> KeyHosting {
        let gh = GitHubCLI.find(programs: programs)
        let accounts = if let gh { await GitHubCLI.accounts(gh, programs: programs) } else { [GitHubAccount]() }
        let signedIn = Set(accounts.map(\.host))
        let hosts = if let remoteURLs {
            KeyHost.hosts(remoteURLs: remoteURLs, gitHubCLIHosts: signedIn)
        } else {
            accounts.compactMap { KeyHost.of(host: $0.host, gitHubCLIHosts: signedIn) }
        }
        return KeyHosting(gh: gh, accounts: accounts, hosts: hosts)
    }
}

/// gh, GitHub's own command-line tool, which can add a new key to the
/// signed-in account (decision 108). Roga uses it for nothing else.
public enum GitHubCLI {
    /// gh on git's `PATH`, or where Homebrew puts it.
    public static func find(programs: Programs) -> String? {
        SigningKeys.find("gh", programs: programs, wellKnown: GitInstallation.homebrewDirectories.map { $0 + "/gh" })
    }

    /// gh's version, for setup's Look Around.
    @concurrent
    public static func version(_ gh: String, programs: Programs) async -> String? {
        var command = ProgramCommand(gh, ["--version"])
        command.timeout = .seconds(5)
        guard let result = try? await programs.run(command), result.succeeded else { return nil }
        return ProgramVersionParser.gh(result.text)
    }

    /// The active account on each host gh is signed in to, from
    /// `gh auth status`, which older versions print to standard error.
    @concurrent
    public static func accounts(_ gh: String, programs: Programs) async -> [GitHubAccount] {
        var command = ProgramCommand(gh, GitHubAuthStatusParser.arguments)
        command.timeout = .seconds(15)
        guard let result = try? await programs.run(command) else { return [] }
        return GitHubAuthStatusParser.parse(result.text + "\n" + result.errorOutput)
    }

    /// What gives gh the scope it needs to add a key of the format, run
    /// once in Terminal, since it signs in again in the browser.
    public static func refreshArguments(host: String, format: CommitIdentity.SigningFormat) -> [String] {
        ["auth", "refresh", "-h", host, "-s", GitHubAccount.scope(for: format)]
    }

    /// What adding a made key runs, by its arguments after `gh`. An SSH key
    /// goes in as a signing key, and an OpenPGP key's armored export comes
    /// in on standard input, which `-` stands for.
    public static func addArguments(_ made: NewSigningKey.Made, title: String, shown: Bool = true) -> [String] {
        switch made.format {
        case .ssh:
            let file = (shown ? made.shownPublicKeyFile : made.publicKeyFile) ?? made.publicKeyFile ?? ""
            return ["ssh-key", "add", file, "--type", "signing", "--title", title]
        case .openPGP, .x509:
            return ["gpg-key", "add", "-", "--title", title]
        }
    }

    /// Adds the made key to the account gh is signed in to on the host.
    ///
    /// - Throws: `NewSigningKey.Failure` with what gh said.
    @concurrent
    public static func add(_ made: NewSigningKey.Made, to host: String, title: String, gh: String, programs: Programs) async throws {
        var command = ProgramCommand(gh, addArguments(made, title: title, shown: false))
        command.environment["GH_HOST"] = host
        command.timeout = .seconds(30)
        let input = made.format == .ssh ? nil : Array(made.publicKey.utf8)
        let result = try await programs.run(command, input: input)
        guard result.succeeded else {
            let words = result.errorOutput.split(whereSeparator: \.isNewline).first.map(String.init) ?? "it exited with \(result.status)"
            throw NewSigningKey.Failure("gh didn't add the key: \(words)")
        }
    }

    /// The title a key gets on the host, which names this Mac, as in
    /// `Signing key on Sam's MacBook Pro`.
    public static var title: String {
        let name = SCDynamicStoreCopyComputerName(nil, nil).map { $0 as String } ?? "this Mac"
        return "Signing key on \(name)"
    }
}

extension RepositorySession {
    /// Where a new key's public half can go, from the repository's remotes,
    /// and whether gh can put it there (decision 108).
    @concurrent
    public nonisolated func keyHosting() async -> KeyHosting {
        let remotes = (try? await RefDetailsLoader.remoteURLs(git: git, in: location.commonDirectory)) ?? [:]
        return await KeyHosting.look(remoteURLs: remotes, programs: Programs(sharingWith: git))
    }
}
