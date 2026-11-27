import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Making keys to sign commits with, and finding the programs git signs
/// with, in a home folder and a GnuPG home the tests make (decision 108).
@Suite(.timeLimit(.minutes(1)))
struct NewSigningKeyTests {
    /// Programs that see no agent, with a GnuPG home when one is given.
    func programs(_ environment: [String: String] = [:]) -> Programs {
        Programs(
            searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            environment: ["SSH_AUTH_SOCK": "/nonexistent"].merging(environment) { $1 }
        )
    }

    /// A home folder with an empty global config, and a git that reads it.
    func makeHome() async throws -> (home: String, git: Git) {
        let home = try makeTemporaryFolder()
        try "".write(toFile: home + "/.gitconfig", atomically: true, encoding: .utf8)
        let git = Git(
            installation: try await TestGit.installation(),
            environment: TestGit.isolatedEnvironment.merging(["HOME": home, "GIT_CONFIG_GLOBAL": home + "/.gitconfig"]) { $1 }
        )
        return (home, git)
    }

    // MARK: SSH

    @Test func makesAnSSHKeyThatGitSignsWithAndSaysIsGood() async throws {
        let (home, git) = try await makeHome()
        let planned = await NewSigningKey.plan(.ssh, name: "Sam Rivera", email: "sam@rivera.dev", git: git, programs: programs(), in: home, home: home)
        guard case .ready(let plan) = planned else {
            Issue.record("Expected a plan, got \(planned)")
            return
        }
        #expect(plan.shownFile == "~/.ssh/id_ed25519_signing")
        #expect(plan.shownArguments == ["-q", "-t", "ed25519", "-C", "sam@rivera.dev", "-N", "", "-f", "~/.ssh/id_ed25519_signing"])
        #expect(plan.arguments.last == home + "/.ssh/id_ed25519_signing")
        #expect(plan.trust?.configArguments == ["config", "--global", "gpg.ssh.allowedSignersFile", "~/.ssh/allowed_signers"])

        // There's no ~/.ssh yet, so making the key makes it too.
        let made = try await NewSigningKey.make(plan, git: git, programs: programs())
        #expect(made.key.value == "~/.ssh/id_ed25519_signing.pub")
        #expect(made.publicKey.hasPrefix("ssh-ed25519 AAAA"))
        #expect(made.publicKey.hasSuffix(" sam@rivera.dev"))
        #expect(made.trustFailure == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: home + "/.ssh")[.posixPermissions] as? Int
        #expect(mode == 0o700)

        // The Key field's menu lists it, as what's written.
        let listing = await SigningKeys.list(.ssh, git: git, programs: programs(), in: home, home: home)
        #expect(listing.keys.map(\.value) == ["~/.ssh/id_ed25519_signing.pub"])

        // A commit signed with what goes in the field is good, since the key
        // is in the allowed signers file.
        let repository = home + "/work"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        _ = try await git.run(GitCommand(["init", "--quiet"], in: repository))
        let settings = ["-c", "user.name=Sam", "-c", "user.email=sam@rivera.dev", "-c", "gpg.format=ssh", "-c", "user.signingkey=\(made.key.value)", "-c", "commit.gpgsign=true"]
        _ = try await git.run(GitCommand(settings + ["commit", "--quiet", "--allow-empty", "-m", "Signed"], in: repository))
        let session = try await RepositorySession.open(containing: repository, git: git)
        let hex = try await git.text(GitCommand(["rev-parse", "HEAD"], in: repository)).trimmingCharacters(in: .whitespacesAndNewlines)
        let check = try await session.checkSignature(of: try #require(ObjectID(hex: hex)))
        #expect(check.result == .good)
    }

    @Test func neverReplacesAKeyThatsThere() async throws {
        let (home, git) = try await makeHome()
        let ssh = home + "/.ssh"
        try FileManager.default.createDirectory(atPath: ssh, withIntermediateDirectories: true)
        try "taken".write(toFile: ssh + "/id_ed25519_signing", atomically: true, encoding: .utf8)
        try "taken".write(toFile: ssh + "/id_ed25519_signing_2.pub", atomically: true, encoding: .utf8)
        #expect(NewSigningKey.freeName(in: ssh) == "id_ed25519_signing_3")

        let planned = await NewSigningKey.plan(.ssh, name: "", email: "sam@rivera.dev", git: git, programs: programs(), in: home, home: home)
        guard case .ready(let plan) = planned else {
            Issue.record("Expected a plan, got \(planned)")
            return
        }
        #expect(plan.shownFile == "~/.ssh/id_ed25519_signing_3")
    }

    @Test func addsToTheAllowedSignersFileGitAlreadyReads() async throws {
        let (home, git) = try await makeHome()
        let file = home + "/trusted"
        _ = try await git.run(GitCommand(["config", "--global", "gpg.ssh.allowedSignersFile", file], in: "/"))
        let planned = await NewSigningKey.plan(.ssh, name: "", email: "sam@rivera.dev", git: git, programs: programs(), in: home, home: home)
        guard case .ready(let plan) = planned else {
            Issue.record("Expected a plan, got \(planned)")
            return
        }
        #expect(plan.trust?.configArguments == nil)
        #expect(plan.trust?.file == file)
        _ = try await NewSigningKey.make(plan, git: git, programs: programs())
        let text = try String(contentsOfFile: file, encoding: .utf8)
        #expect(text.hasPrefix("sam@rivera.dev namespaces=\"git\" ssh-ed25519 AAAA"))
    }

    @Test func saysWhyItCantMakeAKey() async throws {
        let (home, git) = try await makeHome()
        let noEmail = await NewSigningKey.plan(.ssh, name: "Sam", email: " ", git: git, programs: programs(), in: home, home: home)
        #expect(noEmail == .unavailable("Add an email first, since the key is made for it."))

        let x509 = await NewSigningKey.plan(.x509, name: "Sam", email: "sam@rivera.dev", git: git, programs: programs(), in: home, home: home)
        guard case .unavailable = x509 else {
            Issue.record("Expected no plan for X.509")
            return
        }

        _ = try await git.run(GitCommand(["config", "--global", "gpg.ssh.program", "/Applications/1Password.app/Contents/MacOS/op-ssh-sign"], in: "/"))
        let onePassword = await NewSigningKey.plan(.ssh, name: "Sam", email: "sam@rivera.dev", git: git, programs: programs(), in: home, home: home)
        guard case .unavailable(let reason) = onePassword else {
            Issue.record("Expected no plan with 1Password's program")
            return
        }
        #expect(reason.contains("1Password"))
    }

    // MARK: OpenPGP

    static let gpg = ["/opt/homebrew/bin/gpg", "/usr/local/bin/gpg", "/usr/local/MacGPG2/bin/gpg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// A GnuPG home with a short path, since gpg-agent's socket path can't be
    /// longer than 104 bytes.
    func makeGnuPGHome() throws -> String {
        var template = Array("/tmp/rg.XXXXXX".utf8CString)
        let made = try #require(template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) })
        return String(cString: made)
    }

    @Test(.enabled(if: gpg != nil, "gpg isn't installed"))
    func makesAnOpenPGPKeyEvenWhenOneHasTheSameUserID() async throws {
        let gpg = try #require(Self.gpg)
        let gnupgHome = try makeGnuPGHome()
        defer {
            let kill = Process()
            kill.executableURL = URL(filePath: (gpg as NSString).deletingLastPathComponent + "/gpgconf")
            kill.arguments = ["--kill", "gpg-agent"]
            kill.environment = ["GNUPGHOME": gnupgHome]
            try? kill.run()
            kill.waitUntilExit()
            try? FileManager.default.removeItem(atPath: gnupgHome)
        }
        let (home, git) = try await makeHome()
        _ = try await git.run(GitCommand(["config", "--global", "gpg.program", gpg], in: "/"))
        let programs = programs(["GNUPGHOME": gnupgHome])

        var fingerprints: [String] = []
        for _ in 0..<2 {
            let planned = await NewSigningKey.plan(.openPGP, name: "Sam Rivera", email: "sam@rivera.dev", git: git, programs: programs, in: home, home: home)
            guard case .ready(let plan) = planned else {
                Issue.record("Expected a plan, got \(planned)")
                return
            }
            #expect(plan.userID == "Sam Rivera <sam@rivera.dev>")
            #expect(plan.shownArguments == ["--batch", "--yes", "--passphrase", "", "--status-fd", "1", "--quick-generate-key", "Sam Rivera <sam@rivera.dev>", "ed25519", "sign", "never"])
            let made = try await NewSigningKey.make(plan, git: git, programs: programs)
            #expect(made.key.value.count == 40)
            #expect(made.key.title == "Sam Rivera <sam@rivera.dev>")
            #expect(made.publicKey.hasPrefix("-----BEGIN PGP PUBLIC KEY BLOCK-----"))
            fingerprints.append(made.key.value)
        }
        #expect(Set(fingerprints).count == 2)
        let listing = await SigningKeys.list(.openPGP, git: git, programs: programs, in: home, home: home)
        #expect(Set(listing.keys.map(\.value)) == Set(fingerprints))

        // The Signature line's menu exports a key by the ID its signature
        // names, and finds it among this Mac's keys (decision 117).
        let signedWith = SignatureKey(id: String(fingerprints[0].suffix(16)))
        let found = try await SignaturePublicKey.find(signedWith, format: .openPGP, git: git, programs: programs, in: home, home: home)
        #expect(found.isThisMacs)
        #expect(found.key.key.value == fingerprints[0])
        #expect(found.key.publicKey.hasPrefix("-----BEGIN PGP PUBLIC KEY BLOCK-----"))
        // gpg prints nothing for a key it doesn't have.
        await #expect(throws: NewSigningKey.Failure.self) {
            try await SignaturePublicKey.text(of: SignatureKey(id: "0123456789ABCDEF"), format: .openPGP, git: git, programs: programs, in: home)
        }
    }

    // MARK: Programs

    @Test func findsTheProgramsGitSignsWith() async throws {
        let (home, git) = try await makeHome()
        let found = await SigningPrograms.find(git: git, programs: programs(), in: home)
        #expect(found.ssh.isFound)
        #expect(found.ssh.named == "ssh-keygen")
        #expect(found.ssh.setting == nil)
        #expect(found.ssh.hint == nil)
        #expect(found.openPGP.isFound == (Self.gpg != nil))
    }

    @Test func saysWhatsMissingAndWhichSettingNamesIt() async throws {
        let (home, git) = try await makeHome()
        _ = try await git.run(GitCommand(["config", "--global", "gpg.program", "/nonexistent/gpg"], in: "/"))
        _ = try await git.run(GitCommand(["config", "--global", "gpg.x509.program", "smimesign-that-isnt-here"], in: "/"))
        let found = await SigningPrograms.find(git: git, programs: programs(), in: home)
        #expect(!found.openPGP.isFound)
        #expect(found.openPGP.setting == "gpg.program")
        #expect(found.openPGP.hint == "Can't find /nonexistent/gpg (set by gpg.program)")
        #expect(found.openPGP.warning == "Can't find /nonexistent/gpg (set by gpg.program). Commits will fail at signing.")
        #expect(found.x509.hint == "Can't find smimesign-that-isnt-here (set by gpg.x509.program)")

        // gpg.openpgp.program counts before gpg.program.
        _ = try await git.run(GitCommand(["config", "--global", "gpg.openpgp.program", "/usr/bin/true"], in: "/"))
        let again = await SigningPrograms.find(git: git, programs: programs(), in: home)
        #expect(again.openPGP.path == "/usr/bin/true")
    }

    @Test func wordsAMissingDefaultProgram() {
        let gpg = SigningPrograms.Program(format: .openPGP, named: "gpg", path: nil)
        #expect(gpg.hint == "Install GnuPG to sign with OpenPGP")
        #expect(gpg.warning == "Can't find gpg. Commits will fail at signing. Install GnuPG or use SSH.")
        let gpgsm = SigningPrograms.Program(format: .x509, named: "gpgsm", path: nil)
        #expect(gpgsm.hint == "Install GnuPG, which has gpgsm, to sign with X.509")
    }

    // MARK: gh

    @Test func addsAKeyWithTheArgumentsGHTakes() {
        let key = SigningKey(value: "~/.ssh/id_ed25519_signing.pub", title: "~/.ssh/id_ed25519_signing.pub", details: ["ED25519"], fingerprint: "SHA256:x", emails: [])
        let ssh = NewSigningKey.Made(
            format: .ssh,
            key: key,
            publicKey: "ssh-ed25519 AAAA",
            publicKeyFile: "/Users/sam/.ssh/id_ed25519_signing.pub",
            shownPublicKeyFile: "~/.ssh/id_ed25519_signing.pub"
        )
        #expect(GitHubCLI.addArguments(ssh, title: "Signing key on Mac") == ["ssh-key", "add", "~/.ssh/id_ed25519_signing.pub", "--type", "signing", "--title", "Signing key on Mac"])
        #expect(GitHubCLI.addArguments(ssh, title: "T", shown: false)[2] == "/Users/sam/.ssh/id_ed25519_signing.pub")
        #expect(!GitHubCLI.pipesKey(ssh))
        let openPGP = NewSigningKey.Made(format: .openPGP, key: key, publicKey: "-----BEGIN PGP PUBLIC KEY BLOCK-----")
        #expect(GitHubCLI.addArguments(openPGP, title: "T") == ["gpg-key", "add", "-", "--title", "T"])
        #expect(GitHubCLI.pipesKey(openPGP))
        // A key read from a signature, in no file, comes in on standard input
        // too (decision 117).
        let fromSignature = NewSigningKey.Made(format: .ssh, key: key, publicKey: "ssh-ed25519 AAAA")
        #expect(GitHubCLI.addArguments(fromSignature, title: "T", shown: false) == ["ssh-key", "add", "-", "--type", "signing", "--title", "T"])
        #expect(GitHubCLI.pipesKey(fromSignature))
        #expect(GitHubCLI.refreshArguments(host: "github.com", format: .ssh) == ["auth", "refresh", "-h", "github.com", "-s", "admin:ssh_signing_key"])
    }

    @Test func offersTheHostsOfTheRemotesAndWhatGHCanDo() {
        let hosting = KeyHosting(
            gh: "/opt/homebrew/bin/gh",
            accounts: [GitHubAccount(host: "github.com", scopes: ["repo", "admin:ssh_signing_key"])],
            hosts: [.gitHub("github.com"), .gitLab("gitlab.com")]
        )
        #expect(hosting.canAdd(.ssh, to: .gitHub("github.com")))
        #expect(!hosting.canAdd(.openPGP, to: .gitHub("github.com")))
        #expect(!hosting.canAdd(.ssh, to: .gitLab("gitlab.com")))
        let withoutGH = KeyHosting(gh: nil, accounts: hosting.accounts, hosts: hosting.hosts)
        #expect(!withoutGH.canAdd(.ssh, to: .gitHub("github.com")))
    }
}
