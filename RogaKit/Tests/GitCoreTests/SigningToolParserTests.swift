import Foundation
import Testing
@testable import GitCore

/// Reading what gh and the signing programs print, and where a key's public
/// half goes for a repository's remotes (decision 108).
struct SigningToolParserTests {
    @Test func readsTheActiveAccountOfEachHostAndItsScopes() {
        let text = """
        github.com
          ✓ Logged in to github.com account sam (keyring)
          - Active account: true
          - Git operations protocol: https
          - Token: gho_************************************
          - Token scopes: 'gist', 'read:org', 'repo', 'workflow'

          ✓ Logged in to github.com account sam-work (keyring)
          - Active account: false
          - Git operations protocol: ssh
          - Token: gho_************************************
          - Token scopes: 'admin:ssh_signing_key', 'repo'

        github.acme.com
          ✓ Logged in to github.acme.com account sam (GH_ENTERPRISE_TOKEN)
          - Active account: true
          - Token scopes: 'admin:gpg_key', 'repo'

        ghe.broken.com
          X Failed to log in to ghe.broken.com account sam (keyring)
          - Active account: true
          - The token in keyring is invalid.
        """
        let accounts = GitHubAuthStatusParser.parse(text)
        #expect(accounts == [
            GitHubAccount(host: "github.com", scopes: ["gist", "read:org", "repo", "workflow"]),
            GitHubAccount(host: "github.acme.com", scopes: ["admin:gpg_key", "repo"]),
        ])
        #expect(!accounts[0].canAdd(.ssh))
        #expect(!accounts[0].canAdd(.openPGP))
        #expect(accounts[1].canAdd(.openPGP))
        #expect(GitHubAccount(host: "github.com", scopes: ["write:ssh_signing_key"]).canAdd(.ssh))
        #expect(GitHubAuthStatusParser.parse("You are not logged into any GitHub hosts. To log in, run: gh auth login").isEmpty)
    }

    @Test func readsAnOlderStatusWithoutActiveAccounts() {
        let text = """
        github.com
          ✓ Logged in to github.com as sam (oauth_token)
          ✓ Git operations for github.com configured to use https protocol.
          ✓ Token: gho_************************************
          ✓ Token scopes: gist, read:org, repo
        """
        #expect(GitHubAuthStatusParser.parse(text) == [GitHubAccount(host: "github.com", scopes: ["gist", "read:org", "repo"])])
    }

    @Test func readsTheVersions() {
        #expect(ProgramVersionParser.gpg("gpg (GnuPG) 2.4.7\nlibgcrypt 1.11.0\n") == "2.4.7")
        #expect(ProgramVersionParser.openSSH("OpenSSH_9.9p2, LibreSSL 3.3.6\n") == "OpenSSH 9.9p2")
        #expect(ProgramVersionParser.gh("gh version 2.105.0 (2026-11-17)\nhttps://github.com/cli/cli/releases/tag/v2.105.0\n") == "2.105.0")
        #expect(ProgramVersionParser.gh("something else") == nil)
    }

    @Test func readsWhichKeyGPGMade() {
        let text = "[GNUPG:] KEY_CONSIDERED 0A1B 0\n[GNUPG:] KEY_CREATED P 4b5a69784f1e2d3c4b5a69784f1e2d3c4b5a6978\n"
        #expect(OpenPGPStatusParser.createdKey(in: text) == "4B5A69784F1E2D3C4B5A69784F1E2D3C4B5A6978")
        #expect(OpenPGPStatusParser.createdKey(in: "[GNUPG:] KEY_CONSIDERED 0A1B 0") == nil)
    }

    @Test func findsTheHostsOfTheRemotes() {
        #expect(RemoteAddress.host("git@github.com:torvalds/linux.git") == "github.com")
        #expect(RemoteAddress.host("https://sam:token@GitHub.com/torvalds/linux") == "github.com")
        #expect(RemoteAddress.host("ssh://git@ssh.github.com:443/torvalds/linux.git") == "ssh.github.com")
        #expect(RemoteAddress.host("/Users/sam/repos/linux") == nil)
        #expect(RemoteAddress.host("file:///Users/sam/repos/linux") == nil)

        let hosts = KeyHost.hosts(
            remoteURLs: [
                "upstream": "git@gitlab.com:group/project.git",
                "origin": "ssh://git@ssh.github.com:443/sam/project.git",
                "mirror": "https://github.com/sam/project",
                "work": "git@github.acme.com:team/project.git",
                "elsewhere": "https://git.example.com/project.git",
            ],
            gitHubCLIHosts: ["github.acme.com"]
        )
        #expect(hosts == [.gitHub("github.com"), .gitLab("gitlab.com"), .gitHub("github.acme.com")])
        // Without gh signed in to it, an Enterprise host could be anything.
        #expect(KeyHost.of(host: "github.acme.com") == nil)
        #expect(KeyHost.of(host: "gitlab.acme.com") == .gitLab("gitlab.acme.com"))
    }

    @Test func linksToThePageForAddingAKey() {
        #expect(KeyHost.gitHub("github.com").page(for: .ssh)?.absoluteString == "https://github.com/settings/ssh/new")
        #expect(KeyHost.gitHub("github.acme.com").page(for: .openPGP)?.absoluteString == "https://github.acme.com/settings/gpg/new")
        #expect(KeyHost.gitLab("gitlab.com").page(for: .ssh)?.absoluteString == "https://gitlab.com/-/user_settings/ssh_keys")
        #expect(KeyHost.gitLab("gitlab.com").page(for: .x509) == nil)
    }
}
