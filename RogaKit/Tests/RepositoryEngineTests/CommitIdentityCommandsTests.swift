import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Reading and changing who commits go out as, with a global config of the
/// test's own that includes a work identity for one folder.
@Suite(.timeLimit(.minutes(1)))
struct CommitIdentityCommandsTests {
    struct Setup {
        var folder: String
        var globalFile: String
        var git: Git
        /// A repository that the global config's identity applies to.
        var personal: String
        /// A repository in `work`, which the global config gives another email.
        var work: String
    }

    func setUp() async throws -> Setup {
        let folder = try makeTemporaryFolder()
        let globalFile = folder + "/gitconfig"
        let workFile = folder + "/gitconfig-work"
        try """
        [user]
        \tname = Sam Rivera
        \temail = sam@rivera.dev
        [includeIf "gitdir:\(folder)/work/"]
        \tpath = \(workFile)
        """.write(toFile: globalFile, atomically: true, encoding: .utf8)
        try """
        [user]
        \temail = sam.rivera@acme.com
        \tsigningkey = ~/.ssh/acme.pub
        [gpg]
        \tformat = ssh
        [commit]
        \tgpgsign
        """.write(toFile: workFile, atomically: true, encoding: .utf8)
        var environment = TestGit.isolatedEnvironment
        environment["GIT_CONFIG_GLOBAL"] = globalFile
        let git = Git(installation: try await TestGit.installation(), environment: environment)
        for name in ["personal", "work/client"] {
            try FileManager.default.createDirectory(atPath: folder + "/" + name, withIntermediateDirectories: true)
            _ = try await git.run(GitCommand("init", "--quiet", in: folder + "/" + name))
        }
        return Setup(folder: folder, globalFile: globalFile, git: git, personal: folder + "/personal", work: folder + "/work/client")
    }

    @Test func readsTheGlobalIdentityAndWhereItComesFrom() async throws {
        let setup = try await setUp()
        let session = try await RepositorySession.open(containing: setup.personal, git: setup.git)
        let identity = try await session.identity()

        #expect(identity.shownName == "Sam Rivera")
        #expect(identity.shownEmail == "sam@rivera.dev")
        #expect(identity.email?.origin == ConfigOrigin(scope: .global, file: setup.globalFile))
        #expect(!identity.signs)
        #expect(identity.problem == nil)
    }

    @Test func readsAnIncludedIdentity() async throws {
        let setup = try await setUp()
        let session = try await RepositorySession.open(containing: setup.work, git: setup.git)
        let identity = try await session.identity()

        #expect(identity.shownName == "Sam Rivera")
        #expect(identity.shownEmail == "sam.rivera@acme.com")
        #expect(identity.email?.origin == ConfigOrigin(scope: .global, file: setup.folder + "/gitconfig-work"))
        #expect(identity.signs)
        #expect(identity.format == .ssh)
        #expect(identity.key == "~/.ssh/acme.pub")
    }

    @Test func readsTheDefaultIdentityOutsideAnyRepository() async throws {
        let setup = try await setUp()
        let identity = try await CommitIdentityCommands.readDefault(git: setup.git)
        #expect(identity.shownEmail == "sam@rivera.dev")
        #expect(!identity.signs)
    }

    @Test func readsNoIdentity() async throws {
        let setup = try await setUp()
        let git = try await TestGit.make()
        let session = try await RepositorySession.open(containing: setup.personal, git: git)
        let identity = try await session.identity()
        #expect(identity == CommitIdentity())
        #expect(identity.problem == .noEmail)
    }

    @Test func changesTheRepositorysOwnAndGoesBackToTheGlobal() async throws {
        let setup = try await setUp()
        let session = try await RepositorySession.open(containing: setup.personal, git: setup.git)
        try await session.changeIdentity([.set(.email, "sam@oss.example", in: .repository)])

        var identity = try await session.identity()
        #expect(identity.shownEmail == "sam@oss.example")
        #expect(identity.email?.origin.scope == .local)
        let global = try String(contentsOfFile: setup.globalFile, encoding: .utf8)
        #expect(!global.contains("oss.example"))

        // Unsetting what isn't set doesn't fail.
        try await session.changeIdentity([.unset(.email, in: .repository), .unset(.signingKey, in: .repository)])
        identity = try await session.identity()
        #expect(identity.shownEmail == "sam@rivera.dev")
        #expect(identity.email?.origin.scope == .global)
    }

    @Test func changesTheGlobalIdentity() async throws {
        let setup = try await setUp()
        let session = try await RepositorySession.open(containing: setup.personal, git: setup.git)
        try await session.changeIdentity([
            .set(.signsCommits, "true", in: .everyRepository),
            .set(.signingFormat, "ssh", in: .everyRepository),
            .set(.signingKey, "~/.ssh/id.pub", in: .everyRepository),
        ])

        let identity = try await session.identity()
        #expect(identity.signs)
        #expect(identity.format == .ssh)
        #expect(identity.signsCommits?.origin == ConfigOrigin(scope: .global, file: setup.globalFile))
        let config = try await setup.git.text(GitCommand("config", "--local", "--list", in: setup.personal))
        #expect(!config.contains("gpgsign"))
    }

    @Test func saysWhatSavingRuns() {
        typealias Change = CommitIdentityCommands.Change
        #expect(Change.set(.email, "sam@acme.com", in: .repository).arguments == ["config", "--local", "user.email", "sam@acme.com"])
        #expect(Change.unset(.email, in: .repository).arguments == ["config", "--local", "--unset", "user.email"])
        #expect(Change.set(.signsCommits, "false", in: .everyRepository).arguments == ["config", "--global", "commit.gpgsign", "false"])
    }
}
