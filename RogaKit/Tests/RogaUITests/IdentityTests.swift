import AgentHooks
import AppKit
import Foundation
import GitCore
import GitRunner
import IconUI
import MenuUI
import RepositoryEngine
import Testing
import ThemeUI
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
        #expect(IdentityWords.origin(included, globalFiles: globalFiles) == "from ~/.gitconfig-work (included by ~/.gitconfig)")
        #expect(IdentityWords.origin(local, globalFiles: globalFiles) == "set in this repository")
        #expect(IdentityWords.origin(ConfigOrigin(scope: .worktree), globalFiles: globalFiles) == "set in this worktree")
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

    @Test func leavesTheGrayLanesOut() {
        // Monokai's Stone and Xcode's Slate would look like the global
        // identity's gray.
        let monokai = ColorTheme.monokai.colors.lanes
        #expect(IdentityTint.colored(monokai).map(\.light) == monokai.enumerated().filter { $0.offset != 6 }.map(\.element.light))
        let xcode = ColorTheme.xcode.colors.lanes
        #expect(IdentityTint.colored(xcode).map(\.light) == xcode.dropLast().map(\.light))
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

    // MARK: The Key field

    @Test func theKeyFieldKnowsTheKeyItNames() {
        let file = SigningKey(value: "~/.ssh/id_ed25519.pub", title: "~/.ssh/id_ed25519.pub", details: ["ED25519", "sam@rivera.dev"], fingerprint: "SHA256:abc", emails: ["sam@rivera.dev"])
        let fingerprint = "9A8B7C6D5E4F30211A2B3C4D4B5A69784F1E2D3C"
        let openPGP = SigningKey(value: fingerprint, title: "Sam Rivera <sam@rivera.dev>", details: ["ED25519", "4B5A69784F1E2D3C"], fingerprint: fingerprint, emails: ["sam@rivera.dev"])
        let keys = [file, openPGP]
        #expect(SigningKeys.key(named: "~/.ssh/id_ed25519.pub", in: keys) == file)
        // The same file without `~`.
        #expect(SigningKeys.key(named: NSHomeDirectory() + "/.ssh/id_ed25519.pub", in: keys) == file)
        // A long key ID is the end of the fingerprint, in any case.
        #expect(SigningKeys.key(named: "4b5a69784f1e2d3c", in: keys) == openPGP)
        #expect(SigningKeys.key(named: "0x4B5A69784F1E2D3C", in: keys) == openPGP)
        #expect(SigningKeys.key(named: "1E2D3C", in: keys) == nil)
        #expect(SigningKeys.key(named: "  ", in: keys) == nil)
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

    @Test func labelsOnlyTheValuesThatDontComeFromTheGlobalFile() {
        let editor = IdentityEditor(identity: identity(emailFrom: included), defaultIdentity: identity(), globalFiles: globalFiles)
        // From ~/.gitconfig, the global value, which is the usual case.
        #expect(editor.labelWords(.name) == nil)
        // From a file ~/.gitconfig includes, which the label names.
        #expect(editor.labelWords(.email) == "from ~/.gitconfig-work (included by ~/.gitconfig)")
        // Not set, which the switch that's off shows.
        #expect(editor.labelWords(.signsCommits) == nil)
        // Once a field changes, its label says nothing, since Save to and
        // the block along the bottom show what Save will do, and so flipping
        // the switch adds no words beside it.
        editor.email = "sam@oss.example"
        editor.signs = true
        #expect(editor.labelWords(.email) == nil)
        #expect(editor.labelWords(.signsCommits) == nil)

        let setHere = IdentityEditor(identity: identity(emailFrom: local), defaultIdentity: identity(), globalFiles: globalFiles)
        #expect(setHere.labelWords(.email) == "set in this repository")
        setHere.useGlobal(.email)
        #expect(setHere.labelWords(.email) == nil)
    }

    @Test func savesToTheRepositoryByDefault() {
        let editor = IdentityEditor(identity: identity(), defaultIdentity: identity(), globalFiles: globalFiles)
        editor.email = "sam@oss.example"
        #expect(editor.changes == [.set(.email, "sam@oss.example", in: .repository)])
        editor.place = .everyRepository
        #expect(editor.changes == [.set(.email, "sam@oss.example", in: .everyRepository)])
        #expect(editor.shadowNote == nil)
    }

    @Test func removesAFieldThatsEmptied() {
        let editor = IdentityEditor(identity: identity(), defaultIdentity: identity(), globalFiles: globalFiles)
        editor.name = ""
        #expect(editor.changes == [.unset(.name, in: .repository)])
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

    @Test func signsWithOneChoiceOfOffOrAFormat() {
        let editor = IdentityEditor(identity: identity(), defaultIdentity: identity(), globalFiles: globalFiles)
        #expect(editor.signing == nil)
        #expect(editor.signingKeys == [.signsCommits])
        editor.signing = .ssh
        #expect(editor.signs)
        #expect(editor.format == .ssh)
        #expect(editor.signingKeys == [.signsCommits, .signingFormat])
        #expect(editor.changes == [
            .set(.signsCommits, "true", in: .repository),
            .set(.signingFormat, "ssh", in: .repository),
        ])
        // Off leaves the format as it is, so it changes nothing.
        editor.signing = nil
        #expect(editor.format == .ssh)
        #expect(editor.changes.isEmpty)
    }

    @Test func useGlobalOnSignCommitsRemovesBothOfTheRepositorysSettings() {
        var own = identity()
        own.signsCommits = Setting("true", origin: local)
        own.signingFormat = Setting("ssh", origin: local)
        let editor = IdentityEditor(identity: own, defaultIdentity: identity(), globalFiles: globalFiles)
        #expect(editor.signing == .ssh)
        #expect(editor.labelWords(.signsCommits) == "set in this repository")
        let set = editor.signingKeys.filter(editor.canUseGlobal)
        #expect(set == [.signsCommits, .signingFormat])
        set.forEach(editor.useGlobal)
        // The global config doesn't sign, so the format no longer shows, but
        // its removal still runs.
        #expect(editor.signing == nil)
        #expect(editor.changes == [
            .unset(.signsCommits, in: .repository),
            .unset(.signingFormat, in: .repository),
        ])
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
        // Before git has checked, the line says how it's signed, with the
        // plain shield and no spinner (decision 109).
        let before = SignatureWords(format: .openPGP, check: nil)
        #expect(before.title == "Signed with OpenPGP")
        #expect(before.icon == .shield)
        #expect(before.tone == .plain)
        let good = SignatureWords(format: .ssh, check: SignatureCheck(result: .good, signer: "sam@rivera.dev", key: key), email: "sam@rivera.dev")
        #expect(good.title == "Good SSH signature")
        #expect(good.help == "Signed by sam@rivera.dev.")
        #expect(good.tone == .good)
        // Someone other than the committer is named, since the Committer
        // line doesn't say who signed.
        let other = SignatureWords(format: .openPGP, check: SignatureCheck(result: .good, signer: "Alex Kim <alex@example.com>", key: "3AA5"), email: "sam@rivera.dev")
        #expect(other.title == "Good signature from Alex Kim")
        let unchecked = SignatureWords(format: .ssh, check: SignatureCheck(result: .notChecked))
        #expect(unchecked.title == "Signed with SSH, not checked")
        #expect(unchecked.help == "git needs gpg.ssh.allowedSignersFile to know whose keys to trust.")
        #expect(SignatureWords(format: .openPGP, check: SignatureCheck(result: .notChecked)).help == "git couldn't run gpg to check it.")
        #expect(SignatureWords(format: .ssh, check: SignatureCheck(result: .untrusted, key: key)).help == "The allowed signers file doesn't list this key.")
        #expect(SignatureWords(format: .openPGP, check: SignatureCheck(result: .missingKey, key: "3AA5")).title == "Signed with a key not on this Mac")
        #expect(SignatureWords(format: .openPGP, check: SignatureCheck(result: .bad)).tone == .bad)
        #expect(SignatureWords(format: .openPGP, check: SignatureCheck(result: .expired)).tone == .warning)
    }

    @Test func eachTitleFitsOnTheSignaturesLine() {
        // The panel's value column is about 220 points at its default
        // width, which holds about 34 characters of 12-point text.
        let results: [SignatureCheck.Result] = [.good, .untrusted, .expired, .revoked, .bad, .missingKey, .notChecked]
        for format in [CommitIdentity.SigningFormat.ssh, .openPGP, .x509] {
            #expect(SignatureWords(format: format, check: nil).title.count <= 34)
            for result in results {
                let title = SignatureWords(format: format, check: SignatureCheck(result: result)).title
                #expect(title.count <= 34, "\(title)")
            }
        }
        #expect(UserDefaults(suiteName: "checksSignatures-\(UUID())")?.checksSignatures == true)
    }

    /// The chevron's rows, with a disabled row in brackets and a line as `-`.
    func signatureMenu(
        _ format: CommitIdentity.SigningFormat,
        key: SignatureKey?,
        check: SignatureCheck? = nil,
        hosts: [KeyHost] = [.gitHub("github.com")]
    ) -> [String] {
        SignatureLine.menu(format: format, key: key, check: check, hosts: hosts, copyPublicKey: {}, copyID: { _ in }, add: {}).map { entry in
            switch entry {
            case let .command(title, _, isEnabled, _, _): isEnabled ? title.plain : "[\(title.plain)]"
            case .divider: "-"
            default: "?"
            }
        }
    }

    @Test func theSignaturesMenuOffersWhatItCanDoWithTheKey() throws {
        let ssh = try #require(SSHPublicKeyParser.parse("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEl5c7+FTBhBHYT9TKz61AWx/U3+VjN1Mh2idso8ynyp"))
        let sshKey = SignatureKey(id: ssh.fingerprint, ssh: ssh)
        // An SSH signature carries its key, so it's there before git checks.
        #expect(signatureMenu(.ssh, key: sshKey) == ["Copy public key", "Copy fingerprint", "-", "Add to GitHub…"])
        // While the key is read, there's nothing to copy yet.
        #expect(signatureMenu(.ssh, key: nil) == ["[Copy public key]", "[Copy fingerprint]", "-", "[Add to GitHub…]"])
        // Each host's name once, in the remotes' order.
        let hosts: [KeyHost] = [.gitLab("gitlab.com"), .gitHub("github.com"), .gitHub("github.example.com")]
        #expect(signatureMenu(.ssh, key: sshKey, hosts: hosts).last == "Add to GitLab or GitHub…")
        // Without a remote on GitHub or GitLab, copying is what's left.
        #expect(signatureMenu(.ssh, key: sshKey, hosts: []) == ["Copy public key", "Copy fingerprint"])
        // A bad signature's key isn't offered for adding to a host.
        #expect(signatureMenu(.ssh, key: sshKey, check: SignatureCheck(result: .bad)) == ["Copy public key", "Copy fingerprint"])

        // gpg can only export an OpenPGP key it has.
        let pgp = SignatureKey(id: "3AA5C34371567BD2")
        #expect(signatureMenu(.openPGP, key: pgp) == ["Copy public key", "Copy key ID", "-", "Add to GitHub…"])
        #expect(signatureMenu(.openPGP, key: pgp, check: SignatureCheck(result: .good, key: pgp.id)) == ["Copy public key", "Copy key ID", "-", "Add to GitHub…"])
        #expect(signatureMenu(.openPGP, key: pgp, check: SignatureCheck(result: .missingKey, key: pgp.id)) == ["[Copy public key]", "Copy key ID", "-", "[Add to GitHub…]"])

        // An X.509 certificate isn't read, so only its ID, once git names it.
        #expect(signatureMenu(.x509, key: nil) == ["[Copy key ID]"])
        #expect(signatureMenu(.x509, key: nil, check: SignatureCheck(result: .good, key: "0x1234")) == ["Copy key ID"])
    }

    @Test func addingASignaturesKeySaysWhoseItIs() {
        let local = SigningKey(value: "~/.ssh/id_ed25519.pub", title: "~/.ssh/id_ed25519.pub", details: ["ED25519"], fingerprint: "SHA256:x", emails: [])
        let fromFile = NewSigningKey.Made(format: .ssh, key: local, publicKey: "ssh-ed25519 AAAA", publicKeyFile: "/Users/sam/.ssh/id_ed25519.pub", shownPublicKeyFile: "~/.ssh/id_ed25519.pub")
        #expect(AddSignatureKeyPopover.notes(SignaturePublicKey.Found(key: fromFile, isThisMacs: true), email: "sam@rivera.dev") == [
            .init(text: "It's ~/.ssh/id_ed25519.pub, one of this Mac's keys. The host also needs sam@rivera.dev on the same account."),
        ])
        let other = SigningKey(value: "key::ssh-ed25519 AAAA", title: "ED25519 key", details: ["ED25519"], fingerprint: "SHA256:x", emails: [])
        let elsewhere = NewSigningKey.Made(format: .ssh, key: other, publicKey: "ssh-ed25519 AAAA")
        #expect(AddSignatureKeyPopover.notes(SignaturePublicKey.Found(key: elsewhere, isThisMacs: false), email: "") == [
            .init(text: "It isn't one of this Mac's keys, so add it only if it's yours, such as a key from another Mac.", isWarning: true),
        ])
    }

    func trustOffer(setsFile: Bool) throws -> AllowedSigners.Offer {
        let key = try #require(SSHPublicKeyParser.parse("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEl5c7+FTBhBHYT9TKz61AWx/U3+VjN1Mh2idso8ynyp"))
        let local = SigningKey(value: "~/.ssh/id_ed25519.pub", title: "~/.ssh/id_ed25519.pub", details: ["ED25519"], fingerprint: key.fingerprint, emails: [])
        return AllowedSigners.Offer(
            key: key, localKey: local, email: "sam@rivera.dev",
            shownFile: "~/.ssh/allowed_signers", file: "/Users/sam/.ssh/allowed_signers", setsFile: setsFile
        )
    }

    @Test func namesThisMacsKeyWhenItOffersToTrustIt() throws {
        let offer = try trustOffer(setsFile: true)
        #expect(SignatureWords(format: .ssh, check: SignatureCheck(result: .notChecked), offer: offer).help
            == "git needs gpg.ssh.allowedSignersFile to know whose keys to trust. It was signed with ~/.ssh/id_ed25519.pub, one of this Mac's keys.")
        #expect(SignatureWords(format: .ssh, check: SignatureCheck(result: .untrusted, key: offer.key.fingerprint), offer: offer).help
            == "The allowed signers file doesn't list ~/.ssh/id_ed25519.pub, one of this Mac's keys.")
    }

    @Test func theConfirmShowsWhatItRunsAndAdds() throws {
        let line = "sam@rivera.dev namespaces=\"git\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEl5c7+FTBhBHYT9TKz61AWx/U3+VjN1Mh2idso8ynyp"
        #expect(TrustKeyPopover.lines(try trustOffer(setsFile: true)) == [
            .command(["config", "--global", "gpg.ssh.allowedSignersFile", "~/.ssh/allowed_signers"]),
            .comment("Adds this line to ~/.ssh/allowed_signers"),
            .output(line),
        ])
        #expect(TrustKeyPopover.lines(try trustOffer(setsFile: false)) == [.comment("Adds this line to ~/.ssh/allowed_signers"), .output(line)])
    }

    @Test func aSignedRowSaysSo() {
        #expect(CommitRowContent(shortID: "48ba6441", subject: "Add tests", isSigned: true).spokenText == "Add tests, 48ba6441, signed")
        #expect(CommitRowContent(shortID: "48ba6441", subject: "Add tests").spokenText == "Add tests, 48ba6441")
    }

    @Test func aSignedRowKeepsRoomForItsShieldAfterTheWholeShortID() throws {
        let size = NSSize(width: 900, height: 26)
        let signed = CommitRowLayout(content: CommitRowContent(shortID: "48ba6441", subject: "Add tests", isSigned: true), size: size)
        let hash = try #require(signed.columns.first)
        let shield = try #require(signed.signedMark)
        // The short ID isn't cut, and the shield ends inside its column.
        #expect(hash.width >= CommitRowLayout.width(of: "48ba6441", in: CommitCellView.Style.shortID))
        #expect(shield.minX >= hash.x + hash.width + CommitRowLayout.signedMarkGap)
        #expect(shield.maxX <= size.width - 14)
        #expect(shield.width >= 9)
        // The columns don't move for it.
        let unsigned = CommitRowLayout(content: CommitRowContent(shortID: "48ba6441", subject: "Add tests"), size: size)
        #expect(unsigned.signedMark == nil)
        #expect(signed.columns.map(\.x) == unsigned.columns.map(\.x))
        #expect(signed.subjectMaxX == unsigned.subjectMaxX)
        #expect(CommitCellView.signedMarkToolTip == "Signed. Select the commit to check the signature.")
    }

    // MARK: Decision 108

    @Test func aFormatWaitsForItsProgramAndSaysWhatsMissing() {
        // Until the programs are found, only the format git uses can be chosen.
        #expect(IdentityPopover.unavailable(.ssh, programs: nil, current: .openPGP) == "Looking for ssh-keygen…")
        #expect(IdentityPopover.unavailable(.openPGP, programs: nil, current: .openPGP) == nil)

        let found = SigningPrograms.Found(
            ssh: .init(format: .ssh, named: "ssh-keygen", path: "/usr/bin/ssh-keygen"),
            openPGP: .init(format: .openPGP, named: "gpg", path: nil),
            x509: .init(format: .x509, named: "gpgsm", path: nil)
        )
        #expect(IdentityPopover.unavailable(.ssh, programs: found, current: .ssh) == nil)
        #expect(IdentityPopover.unavailable(.openPGP, programs: found, current: .ssh) == "Install GnuPG to sign with OpenPGP")
        #expect(IdentityPopover.unavailable(.x509, programs: found, current: .ssh) == "Install GnuPG, which has gpgsm, to sign with X.509")
        // The format git signs with stays, and the popover warns instead.
        #expect(IdentityPopover.unavailable(.openPGP, programs: found, current: .openPGP) == nil)
        // While commits aren't signed, git's default is faded like the rest.
        #expect(IdentityPopover.unavailable(.openPGP, programs: found, current: nil) == "Install GnuPG to sign with OpenPGP")
    }

    func sshPlan(setsFile: Bool = true) -> NewSigningKey.Plan {
        NewSigningKey.Plan(
            format: .ssh,
            email: "sam@rivera.dev",
            userID: "sam@rivera.dev",
            program: "/usr/bin/ssh-keygen",
            arguments: ["-q", "-t", "ed25519", "-C", "sam@rivera.dev", "-N", "", "-f", "/Users/sam/.ssh/id_ed25519_signing"],
            shownArguments: ["-q", "-t", "ed25519", "-C", "sam@rivera.dev", "-N", "", "-f", "~/.ssh/id_ed25519_signing"],
            shownFile: "~/.ssh/id_ed25519_signing",
            file: "/Users/sam/.ssh/id_ed25519_signing",
            trust: NewSigningKey.Trust(shownFile: "~/.ssh/allowed_signers", file: "/Users/sam/.ssh/allowed_signers", setsFile: setsFile)
        )
    }

    @Test func theNewKeyConfirmSaysWhatItMakesAndRuns() {
        let plan = sshPlan()
        #expect(NewKeyPopover.facts(plan) == [
            .init(label: "Email", value: "sam@rivera.dev"),
            .init(label: "File", value: "~/.ssh/id_ed25519_signing"),
        ])
        #expect(NewKeyPopover.note(plan) == "Roga makes an Ed25519 key without a passphrase, so git, Roga and agents can sign without asking. Anyone who can read the file can sign as you. It also goes in ~/.ssh/allowed_signers, so git says your commits are good.")
        #expect(NewKeyPopover.lines(plan) == [
            .program(plan.command),
            .command(["config", "--global", "gpg.ssh.allowedSignersFile", "~/.ssh/allowed_signers"]),
            .comment("Adds the new key to ~/.ssh/allowed_signers for sam@rivera.dev"),
        ])
        #expect(plan.command.description.hasSuffix("-N '' -f ~/.ssh/id_ed25519_signing"))
        #expect(NewKeyPopover.lines(sshPlan(setsFile: false)).count == 2)

        let openPGP = NewSigningKey.Plan(
            format: .openPGP,
            email: "sam@rivera.dev",
            name: "Sam Rivera",
            userID: "Sam Rivera <sam@rivera.dev>",
            program: "/opt/homebrew/bin/gpg",
            arguments: [],
            shownArguments: []
        )
        #expect(NewKeyPopover.facts(openPGP) == [
            .init(label: "Name", value: "Sam Rivera"),
            .init(label: "Email", value: "sam@rivera.dev"),
        ])
        #expect(NewKeyPopover.note(openPGP) == "Roga makes an Ed25519 key that doesn't expire, without a passphrase, so git, Roga and agents can sign without asking. Anyone who can use your GnuPG keyring can sign as you.")
    }

    @Test func theMadeKeySaysWhereItCanGo() {
        let key = SigningKey(value: "~/.ssh/id_ed25519_signing.pub", title: "~/.ssh/id_ed25519_signing.pub", details: ["ED25519"], fingerprint: "SHA256:x", emails: [])
        let made = NewSigningKey.Made(format: .ssh, key: key, publicKey: "ssh-ed25519 AAAA", publicKeyFile: "/Users/sam/.ssh/id_ed25519_signing.pub", shownPublicKeyFile: "~/.ssh/id_ed25519_signing.pub")
        let gitHub = KeyHost.gitHub("github.com")
        let gh = "/opt/homebrew/bin/gh"

        let canAdd = KeyHosting(gh: gh, accounts: [GitHubAccount(host: "github.com", scopes: ["admin:ssh_signing_key"])], hosts: [gitHub])
        #expect(KeyHostsContent.hostWords(gitHub, format: .ssh, hosting: canAdd, isAdded: false) == "gh can add it as a signing key, so commits signed with it show as Verified.")
        #expect(KeyHostsContent.hostWords(gitHub, format: .ssh, hosting: canAdd, isAdded: true) == "Added as a signing key, so commits signed with it show as Verified.")
        #expect(KeyHostsContent.lines(made, hosting: canAdd, added: []) == [
            .program(ProgramCommand(gh, ["ssh-key", "add", "~/.ssh/id_ed25519_signing.pub", "--type", "signing", "--title", GitHubCLI.title])),
        ])

        // Signed in, but without the scope: the command that gives it.
        let noScope = KeyHosting(gh: gh, accounts: [GitHubAccount(host: "github.com", scopes: ["repo"])], hosts: [gitHub])
        #expect(KeyHostsContent.hostWords(gitHub, format: .ssh, hosting: noScope, isAdded: false).hasPrefix("gh may not add signing keys yet."))
        #expect(KeyHostsContent.lines(made, hosting: noScope, added: []) == [
            .comment("Lets gh add keys to github.com. Run it once in Terminal."),
            .program(ProgramCommand(gh, ["auth", "refresh", "-h", "github.com", "-s", "admin:ssh_signing_key"])),
        ])

        // Without gh, GitHub's page, and GitLab's for a GitLab remote.
        let noGH = KeyHosting(gh: nil, accounts: [], hosts: [gitHub, .gitLab("gitlab.com")])
        #expect(KeyHostsContent.hostWords(gitHub, format: .ssh, hosting: noGH, isAdded: false) == "Add it on GitHub as a signing key, so commits signed with it show as Verified. Open GitHub copies it first.")
        #expect(KeyHostsContent.hostWords(.gitLab("gitlab.com"), format: .ssh, hosting: noGH, isAdded: false) == "Add it on GitLab with the usage type Signing, so commits signed with it show as Verified. Open GitLab copies it first.")
        #expect(KeyHostsContent.lines(made, hosting: noGH, added: []) == [.comment("Copy Public Key copies ~/.ssh/id_ed25519_signing.pub")])

        #expect(NewKeyPopover.madeNotes(made, savesAtOnce: true) == [.init(text: "Commits are signed with it now.")])
        var untrusted = made
        untrusted.trustFailure = "no folder"
        #expect(NewKeyPopover.madeNotes(untrusted, savesAtOnce: false) == [
            .init(text: "It's in the Key field. Save to sign commits with it."),
            .init(text: "Roga couldn't add it to the allowed signers file: no folder", isWarning: true),
        ])
    }

    /// The key that signed a commit, which is in no file when it isn't this
    /// Mac's, goes into gh on standard input (decision 117).
    @Test func aKeyFromASignatureIsPipedIntoGH() {
        let key = SigningKey(value: "key::ssh-ed25519 AAAA", title: "ED25519 key", details: ["ED25519"], fingerprint: "SHA256:x", emails: [])
        let fromSignature = NewSigningKey.Made(format: .ssh, key: key, publicKey: "ssh-ed25519 AAAA")
        let gh = "/opt/homebrew/bin/gh"
        let canAdd = KeyHosting(gh: gh, accounts: [GitHubAccount(host: "github.com", scopes: ["admin:ssh_signing_key"])], hosts: [.gitHub("github.com")])
        #expect(KeyHostsContent.lines(fromSignature, hosting: canAdd, added: []) == [
            .comment("Add to GitHub pipes in the public key"),
            .program(ProgramCommand(gh, ["ssh-key", "add", "-", "--type", "signing", "--title", GitHubCLI.title])),
        ])
        #expect(KeyHostsContent.lines(fromSignature, hosting: KeyHosting(gh: nil, accounts: [], hosts: []), added: []) == [
            .comment("Copy Public Key copies the public key"),
        ])
    }

    @Test func setupSaysWhatItFoundForSigning() {
        #expect(SetupWords.signingLooks(nil, hasGit: false, gitFailed: true).map(\.detail) == ["After Git", "After Git", "After Git"])
        #expect(SetupWords.signingLooks(nil, hasGit: true, gitFailed: false).map(\.state) == [.looking, .looking, .looking])
        let tools = SetupWords.SigningTools(
            ssh: .init(isFound: true, version: "OpenSSH 9.9p2"),
            gnuPG: .init(isFound: true, version: "2.4.7"),
            hasGPGSM: true,
            gitHubCLI: .init(isFound: false)
        )
        let looks = SetupWords.signingLooks(tools, hasGit: true, gitFailed: false)
        #expect(looks.map(\.name) == ["SSH", "GnuPG", "GitHub CLI"])
        #expect(looks.map(\.detail) == [
            "OpenSSH 9.9p2 · for signing commits with SSH",
            "2.4.7 · for signing with OpenPGP and X.509",
            "Not found · optional, for adding keys to GitHub",
        ])
        // Like an agent that isn't there, a missing tool isn't a warning.
        #expect(looks.allSatisfy { $0.state == .found })
    }
}
