import AgentHooks
import Foundation
import GitCore
import RepositoryEngine
import Testing
@testable import HistoryUI
@testable import RogaUI

/// What the window says about who commits go out as, and what the identity
/// popover runs (decisions 103 and 105).
struct IdentityTests {
    typealias Setting = CommitIdentity.Setting
    let globalFiles = GlobalConfigFiles(home: "/Users/sam", environment: [:])

    var global: ConfigOrigin { ConfigOrigin(scope: .global, file: "/Users/sam/.gitconfig") }
    var included: ConfigOrigin { ConfigOrigin(scope: .global, file: "/Users/sam/.gitconfig-work") }
    var local: ConfigOrigin { ConfigOrigin(scope: .local, file: "config") }

    func identity(
        name: String? = "Sam Rivera",
        email: String? = "sam@rivera.dev",
        emailFrom: ConfigOrigin? = nil,
        signs: Bool = false,
        format: String? = nil,
        key: String? = nil
    ) -> CommitIdentity {
        CommitIdentity(
            name: name.map { Setting($0, origin: global) },
            email: email.map { Setting($0, origin: emailFrom ?? global) },
            signingKey: key.map { Setting($0, origin: global) },
            signsCommits: signs ? Setting("true", origin: global) : nil,
            signingFormat: format.map { Setting($0, origin: global) }
        )
    }

    // MARK: Words

    @Test func saysWhoWhereFromAndHowSigned() {
        let words = IdentityWords(identity: identity(signs: true, format: "ssh", key: "~/.ssh/id_ed25519.pub"), globalFiles: globalFiles)
        #expect(words.tooltip == "Sam Rivera <sam@rivera.dev>\nFrom ~/.gitconfig\nSigned with SSH · ~/.ssh/id_ed25519.pub")
        #expect(IdentityWords(identity: identity(), globalFiles: globalFiles).signing == "Not signed")
    }

    @Test func saysWhereAnIncludedOrOwnSettingComesFrom() {
        #expect(IdentityWords.origin(included, globalFiles: globalFiles) == "from ~/.gitconfig-work, which ~/.gitconfig includes")
        #expect(IdentityWords.origin(local, globalFiles: globalFiles) == "this repository's own")
        #expect(IdentityWords.origin(ConfigOrigin(scope: .worktree), globalFiles: globalFiles) == "this worktree's own")
        #expect(IdentityWords.origin(ConfigOrigin(scope: .system, file: "/etc/gitconfig"), globalFiles: globalFiles) == "from /etc/gitconfig")
    }

    @Test func saysWhatsWrong() {
        let noEmail = IdentityWords(identity: identity(email: nil), globalFiles: globalFiles)
        #expect(noEmail.who == "Sam Rivera, with no email")
        #expect(noEmail.signing.hasPrefix("git would refuse to commit"))
        let noKey = IdentityWords(identity: identity(signs: true, format: "ssh"), globalFiles: globalFiles)
        #expect(noKey.signing.hasPrefix("Signing with SSH is on, but no key is set"))
    }

    @Test func findsTheGlobalConfig() {
        #expect(GlobalConfigFiles(home: "/Users/sam", environment: [:]).paths == ["/Users/sam/.gitconfig", "/Users/sam/.config/git/config"])
        #expect(GlobalConfigFiles(home: "/Users/sam", environment: ["XDG_CONFIG_HOME": "/x"]).paths == ["/Users/sam/.gitconfig", "/x/git/config"])
        #expect(GlobalConfigFiles(home: "/Users/sam", environment: ["GIT_CONFIG_GLOBAL": "/tmp/g"]).paths == ["/tmp/g"])
    }

    @Test func tintsAnEmailTheSameEveryTime() {
        #expect(IdentityTint.hash("sam@rivera.dev") == IdentityTint.hash("sam@rivera.dev"))
        #expect(IdentityTint.hash("sam@rivera.dev") != IdentityTint.hash("sam.rivera@acme.com"))
        #expect(IdentityTint.color(for: identity(email: nil)) == nil)
    }

    // MARK: Exceptions

    @Test func theGlobalIdentityIsntAnException() {
        #expect(IdentityException(identity(), defaultIdentity: identity()) == nil)
        // Signing doesn't make it someone else.
        #expect(IdentityException(identity(signs: true), defaultIdentity: identity()) == nil)
        // Nor does anything, before the global identity is read.
        #expect(IdentityException(identity(email: "sam@acme.com"), defaultIdentity: nil) == nil)
        #expect(IdentityException(nil, defaultIdentity: identity()) == nil)
    }

    @Test func someoneElseIsAnException() {
        let work = identity(email: "sam.rivera@acme.com", emailFrom: included)
        #expect(IdentityException(work, defaultIdentity: identity()) == .someoneElse(work))
    }

    @Test func whatWouldGoWrongComesFirst() {
        #expect(IdentityException(identity(email: nil), defaultIdentity: identity()) == .problem(.noEmail))
        #expect(IdentityException(identity(signs: true, format: "ssh"), defaultIdentity: nil) == .problem(.noSigningKey))
    }

    // MARK: The title row and the message box

    @Test func thePersonIsPlainForTheGlobalIdentity() {
        #expect(IdentityPerson.Look(IdentityException(identity(signs: true), defaultIdentity: identity())) == .plain)
        let work = identity(email: "sam.rivera@acme.com", emailFrom: included)
        #expect(IdentityPerson.Look(.someoneElse(work)) == .tinted(IdentityTint.color(for: work)))
        #expect(IdentityPerson.Look(.problem(.noSigningKey)) == .warning)
    }

    @Test func thePersonHasAShieldWhileCommitsAreSigned() {
        #expect(IdentityPerson.Mark(.plain, signs: true) == .shield)
        #expect(IdentityPerson.Mark(.tinted(nil), signs: true) == .shield)
        #expect(IdentityPerson.Mark(.plain, signs: false) == nil)
        #expect(IdentityPerson.Mark(.tinted(nil), signs: false) == nil)
        // What would go wrong matters more than how it'd be signed.
        #expect(IdentityPerson.Mark(.warning, signs: true) == .warning)
        #expect(IdentityPerson.Mark(.warning, signs: false) == .warning)
    }

    @Test func theBoxAlwaysSaysWho() {
        #expect(CommitBoxIdentity(identity(), defaultIdentity: identity()) == .line(identity(), isSomeoneElse: false))
        let work = identity(email: "sam.rivera@acme.com", emailFrom: included)
        #expect(CommitBoxIdentity(work, defaultIdentity: identity()) == .line(work, isSomeoneElse: true))
        // Before the global identity is read, nothing says it's someone else.
        #expect(CommitBoxIdentity(work, defaultIdentity: nil) == .line(work, isSomeoneElse: false))
    }

    @Test func theBoxWarnsInTheLinesPlace() {
        #expect(CommitBoxIdentity(identity(email: nil), defaultIdentity: identity()) == .warning(.noEmail))
        #expect(CommitBoxIdentity(identity(signs: true, format: "ssh"), defaultIdentity: identity()) == .warning(.noSigningKey))
    }

    @Test func theBoxKeepsTheLinesRoomUntilGitAnswers() {
        #expect(CommitBoxIdentity(nil, defaultIdentity: identity()) == .unread)
        #expect(CommitBoxIdentity(nil, defaultIdentity: nil) == .unread)
    }

    // MARK: The popover

    @Test func savesNothingUntilSomethingChanges() {
        let editor = IdentityEditor(identity: identity(), defaultIdentity: identity(), globalFiles: globalFiles)
        #expect(editor.changes.isEmpty)
        #expect(editor.originWords(.email) == "from ~/.gitconfig")
        #expect(editor.originWords(.signingKey) == "not set")
        editor.email = "  sam@rivera.dev "
        #expect(editor.changes.isEmpty)
    }

    @Test func savesToTheRepositoryByDefault() {
        let editor = IdentityEditor(identity: identity(), defaultIdentity: identity(), globalFiles: globalFiles)
        editor.email = "sam@oss.example"
        #expect(editor.changes == [.set(.email, "sam@oss.example", in: .repository)])
        #expect(editor.originWords(.email) == "this repository's own, once saved")
        editor.place = .everyRepository
        #expect(editor.changes == [.set(.email, "sam@oss.example", in: .everyRepository)])
        #expect(editor.originWords(.email) == "in ~/.gitconfig, once saved")
        #expect(editor.shadowNote == nil)
    }

    @Test func removesAFieldThatsEmptied() {
        let editor = IdentityEditor(identity: identity(), defaultIdentity: identity(), globalFiles: globalFiles)
        editor.name = ""
        #expect(editor.changes == [.unset(.name, in: .repository)])
        #expect(editor.originWords(.name) == "removed from this repository once saved")
    }

    @Test func turnsSigningOnWithAFormatAndAKey() {
        let editor = IdentityEditor(identity: identity(), defaultIdentity: identity(), globalFiles: globalFiles)
        editor.signs = true
        #expect(editor.changes == [.set(.signsCommits, "true", in: .repository)])
        editor.format = .ssh
        editor.key = "~/.ssh/id_ed25519.pub"
        #expect(editor.changes == [
            .set(.signsCommits, "true", in: .repository),
            .set(.signingFormat, "ssh", in: .repository),
            .set(.signingKey, "~/.ssh/id_ed25519.pub", in: .repository),
        ])
        // Turning it off again leaves the format and the key alone.
        editor.signs = false
        #expect(editor.changes.isEmpty)
    }

    @Test func goesBackToTheGlobalValue() {
        let own = identity(email: "sam@oss.example", emailFrom: local)
        let editor = IdentityEditor(identity: own, defaultIdentity: identity(), globalFiles: globalFiles)
        #expect(editor.canUseGlobal(.email))
        #expect(!editor.canUseGlobal(.name))
        editor.useGlobal(.email)
        #expect(editor.email == "sam@rivera.dev")
        #expect(!editor.canUseGlobal(.email))
        #expect(editor.changes == [.unset(.email, in: .repository)])
        // Even when it saves the rest to every repository.
        editor.place = .everyRepository
        editor.name = "Sam R."
        #expect(editor.changes == [.set(.name, "Sam R.", in: .everyRepository), .unset(.email, in: .repository)])
        // Typing another email sets that instead.
        editor.email = "sam@elsewhere.example"
        #expect(editor.changes == [.set(.name, "Sam R.", in: .everyRepository), .set(.email, "sam@elsewhere.example", in: .everyRepository)])
    }

    @Test func saysWhenTheGlobalConfigWouldntChangeThisRepository() {
        let own = IdentityEditor(identity: identity(email: "sam@oss.example", emailFrom: local), defaultIdentity: identity(), globalFiles: globalFiles)
        own.email = "sam@new.example"
        #expect(own.shadowNote == nil)
        own.place = .everyRepository
        #expect(own.shadowNote == "This repository sets its own email, so saving it for every repository won't change it here.")

        let work = IdentityEditor(identity: identity(email: "sam.rivera@acme.com", emailFrom: included), defaultIdentity: identity(), globalFiles: globalFiles)
        work.place = .everyRepository
        work.email = "sam@acme.com"
        #expect(work.shadowNote == "~/.gitconfig-work sets the email for this repository, so saving it for every repository won't change it here.")
    }

    // MARK: The sidebar and Settings

    @Test func theSidebarsSecondLineSaysWhatsWrongLast() throws {
        let working = AgentSummary(state: .working, since: .now, hosts: [.claude], sessions: 1)
        let waiting = AgentSummary(state: .waiting(.permission), since: .now, hosts: [.claude], sessions: 1)
        let conflicts = try #require(UnfinishedWork(work: nil, conflicts: 2))
        #expect(RowLine(agent: nil, unfinished: nil, identity: .noEmail) == .identity(.noEmail))
        #expect(RowLine(agent: working, unfinished: nil, identity: .noEmail) == .agent(working))
        #expect(RowLine(agent: nil, unfinished: conflicts, identity: .noEmail) == .unfinished(conflicts))
        #expect(RowLine(agent: waiting, unfinished: conflicts, identity: .noSigningKey) == .agent(waiting))
        #expect(RowLine(agent: nil, unfinished: nil) == nil)
    }

    @Test func settingsListsRepositoriesThatAFileGivesOneIdentityTogether() {
        let work = identity(email: "sam.rivera@acme.com", emailFrom: included)
        let own = identity(email: "sam@oss.example", emailFrom: local)
        let api = ListedRepository(path: "/git/api/.git", identity: work)
        let billing = ListedRepository(path: "/git/billing/.git", identity: work)
        let tools = ListedRepository(path: "/git/tools/.git", identity: own)
        let legacy = ListedRepository(path: "/git/legacy/.git", identity: identity(email: nil))
        let roga = ListedRepository(path: "/git/roga/.git", identity: identity())
        let list = RepositoryList(listing: [api, tools, billing, legacy, roga], defaultIdentity: identity())

        let rows = IdentityExceptionRow.rows(list.identityExceptions)
        #expect(rows.map(\.names) == ["api and billing", "tools", "legacy"])
        #expect(rows.map(\.canUseGlobal) == [false, true, false])
        #expect(rows[2].exception == .problem(.noEmail))
    }

    @Test func aBareRepositoryIsntAnException() {
        let bare = ListedRepository(
            path: "/git/mirror.git",
            worktrees: [Worktree(path: "/git/mirror.git", head: nil, branch: nil, isBare: true)],
            identity: identity(email: nil)
        )
        let list = RepositoryList(listing: [bare], defaultIdentity: identity())
        #expect(list.identityExceptions.isEmpty)
    }

    @Test func saysWhoARowCommitsAs() {
        #expect(IdentityWords.spoken(.someoneElse(identity(email: "sam@oss.example"))) == "Commits as sam@oss.example")
        #expect(IdentityWords.spoken(.problem(.noEmail)) == "No email for commits")
    }

    // MARK: Signed commits

    @Test func saysWhatCheckingASignatureFound() {
        let key = "SHA256:abc"
        #expect(SignatureWords(format: .ssh, check: nil).title == "Checking…")
        let good = SignatureWords(format: .ssh, check: SignatureCheck(result: .good, signer: "sam@rivera.dev", key: key))
        #expect(good.title == "Good SSH signature")
        #expect(good.detail == "sam@rivera.dev · SHA256:abc")
        #expect(good.tone == .good)
        let unchecked = SignatureWords(format: .ssh, check: SignatureCheck(result: .notChecked))
        #expect(unchecked.title == "Signed with SSH, not checked")
        #expect(unchecked.detail == "git needs gpg.ssh.allowedSignersFile to know whose keys to trust.")
        #expect(SignatureWords(format: .openPGP, check: SignatureCheck(result: .notChecked)).detail == "git couldn't run gpg to check it.")
        #expect(SignatureWords(format: .ssh, check: SignatureCheck(result: .untrusted, key: key)).detail == "The allowed signers file doesn't list this key. SHA256:abc")
        #expect(SignatureWords(format: .openPGP, check: SignatureCheck(result: .missingKey, key: "3AA5")).detail == "OpenPGP key 3AA5")
        #expect(SignatureWords(format: .openPGP, check: SignatureCheck(result: .bad)).tone == .bad)
        #expect(SignatureWords(format: .openPGP, check: SignatureCheck(result: .expired)).tone == .warning)
    }

    @Test func aSignedRowSaysSo() {
        #expect(CommitRowContent(shortID: "48ba6441", subject: "Add tests", isSigned: true).spokenText == "Add tests, 48ba6441, signed")
        #expect(CommitRowContent(shortID: "48ba6441", subject: "Add tests").spokenText == "Add tests, 48ba6441")
    }
}
