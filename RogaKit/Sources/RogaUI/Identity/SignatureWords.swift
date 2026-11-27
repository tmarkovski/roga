import AppKit
import GitCore
import IconUI
import MenuUI
import RepositoryEngine
import SwiftUI

extension UserDefaults {
    /// Whether the commit panel checks a signed commit's signature as the
    /// commit shows (decision 109).
    static let checksSignaturesKey = "checksSignatures"

    /// Whether the commit panel checks a signed commit's signature as the
    /// commit shows, which it does unless the user turned that off.
    var checksSignatures: Bool {
        object(forKey: Self.checksSignaturesKey) as? Bool ?? true
    }
}

/// The commit panel's line under the author for a signed commit (decisions
/// 104 and 109). It says at once how the commit is signed and which key
/// made the signature, which Roga reads from the commit itself, and then
/// checks the signature in the background, which changes only the mark and
/// the words on its first line, so that nothing under it moves.
///
/// The check waits a moment, so that moving through history with the arrow
/// keys doesn't run gpg or ssh-keygen for every commit on the way, and a
/// check that's still running stops when another commit shows. With
/// checking turned off in Settings, Check does it for this commit. When git
/// couldn't vouch for an SSH signature made with one of this Mac's keys, the
/// key's line ends with Trust This Key… (decision 107). The chevron after the
/// words opens what can be done with the key: copy its public half or its
/// fingerprint, or add it to GitHub or GitLab (decision 117).
struct SignatureLine: View {
    let commit: ObjectID
    let format: CommitIdentity.SigningFormat
    /// The committer's email, which trusting the key is for, and which a
    /// good signature's signer is compared with.
    let email: String
    let session: RepositorySession
    @AppStorage(UserDefaults.checksSignaturesKey) private var checksByItself = true
    /// The key read from the signature, and for which commit.
    @State private var key: (commit: ObjectID, key: SignatureKey?)?
    /// The GitHub and GitLab hosts the repository's remotes are on, which
    /// Add to GitHub… names.
    @State private var hosts: [KeyHost] = []
    /// The key Add to GitHub… is adding, while its popover is open.
    @State private var adding: SignatureKey?
    /// What the check found, and for which commit, so that a line that's
    /// reused for the next commit doesn't show the last one's.
    @State private var found: Found?
    /// How many times a key has been trusted here, so that the commit is
    /// checked again after each.
    @State private var trusts = 0
    /// The commit Check was clicked for, while checking is off.
    @State private var requested: ObjectID?

    struct Found: Equatable {
        var commit: ObjectID
        var check: SignatureCheck?
        var failure: String?
        var offer: AllowedSigners.Offer?
    }

    /// What starts a check: another commit, a key just trusted, Check, or
    /// checking turned on.
    private struct Check: Hashable {
        var commit: ObjectID
        var trusts: Int
        var isWanted: Bool
    }

    /// How long a commit shows before its signature is checked.
    static let pause = Duration.milliseconds(150)

    /// How git's answer comes in: the first line's mark and words fade from
    /// Signed with… to what git found. Showing another commit doesn't fade,
    /// so that moving through history stays quick.
    static let answer = Animation.easeInOut(duration: 0.25)

    var body: some View {
        let shown = found?.commit == commit ? found : nil
        let readKey = key?.commit == commit ? key?.key : nil
        let words = shown?.failure.map { SignatureWords.failed($0) }
            ?? SignatureWords(format: format, check: shown?.check, email: email, offer: shown?.offer)
        let isWanted = checksByItself || requested == commit
        SignatureLineContent(
            words: words,
            key: readKey?.id ?? shown?.check?.key,
            check: isWanted || shown != nil ? nil : { requested = commit }
        ) {
            if let offer = shown?.offer {
                TrustKeyButton(offer: offer, session: session) { trusts += 1 }
                    .transition(.opacity)
            }
        } menu: {
            SignatureMenuButton(entries: menu(key: readKey, check: shown?.check))
                .popover(isPresented: Binding { adding != nil } set: { if !$0 { adding = nil } }, arrowEdge: .bottom) {
                    if let adding {
                        AddSignatureKeyPopover(key: adding, format: format, email: email, session: session) { self.adding = nil }
                    }
                }
        }
        // Reading the key costs one git cat-file and no gpg, so it doesn't wait.
        .task(id: commit) {
            let read = await session.signatureKey(of: commit)
            guard !Task.isCancelled else { return }
            key = (commit, read)
        }
        // Remotes don't change from one commit to the next.
        .task {
            hosts = await session.remoteKeyHosts()
        }
        .task(id: Check(commit: commit, trusts: trusts, isWanted: isWanted)) {
            guard isWanted else { return }
            // A check after trusting a key, or after Check, needn't wait.
            if trusts == 0 || found?.commit != commit, requested != commit {
                guard (try? await Task.sleep(for: Self.pause)) != nil else { return }
            }
            let check: SignatureCheck
            do {
                check = try await session.checkSignature(of: commit)
            } catch {
                guard !Task.isCancelled else { return }
                withAnimation(Self.answer) { found = Found(commit: commit, failure: String(describing: error)) }
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(Self.answer) { found = Found(commit: commit, check: check) }
            // Only an SSH signature waits on the allowed signers file.
            guard format == .ssh, [.notChecked, .untrusted].contains(check.result),
                  let offer = await session.allowedSignersOffer(for: commit, email: email),
                  !Task.isCancelled
            else { return }
            withAnimation(Self.answer) { found = Found(commit: commit, check: check, offer: offer) }
        }
    }

    /// The chevron's menu for this commit's key.
    private func menu(key: SignatureKey?, check: SignatureCheck?) -> [RefMenu.Entry] {
        Self.menu(
            format: format,
            key: key,
            check: check,
            hosts: hosts,
            copyPublicKey: {
                guard let key else { return }
                Task {
                    do {
                        copy(try await session.publicKey(of: key, format: format))
                    } catch {
                        NSSound.beep()
                    }
                }
            },
            copyID: { id in copy(id) },
            add: { adding = key }
        )
    }

    /// What the chevron after the words offers for the key that made the
    /// signature (decision 117). An SSH signature carries its public key,
    /// so it can always be copied. gpg exports an OpenPGP key only when it
    /// has it, which git's answer rules out for a key not on this Mac. X.509
    /// certificates aren't read, so only their ID can be copied, once git
    /// names it. A bad signature, or one made with a revoked key, isn't
    /// offered for adding to a host.
    static func menu(
        format: CommitIdentity.SigningFormat,
        key: SignatureKey?,
        check: SignatureCheck?,
        hosts: [KeyHost],
        copyPublicKey: @escaping () -> Void,
        copyID: @escaping (String) -> Void,
        add: @escaping () -> Void
    ) -> [RefMenu.Entry] {
        let id = key?.id ?? check?.key
        let canCopyPublicKey = switch format {
        case .ssh: key?.ssh != nil
        case .openPGP: key != nil && ![.missingKey, .notChecked].contains(check?.result)
        case .x509: false
        }
        var entries: [RefMenu.Entry] = []
        if format != .x509 {
            entries.append(.command("Copy public key", isEnabled: canCopyPublicKey, action: copyPublicKey))
        }
        entries.append(.command(format == .ssh ? "Copy fingerprint" : "Copy key ID", isEnabled: id != nil) {
            if let id { copyID(id) }
        })
        let names = hosts.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if format != .x509, !names.isEmpty, ![.bad, .revoked].contains(check?.result) {
            entries.append(.divider)
            entries.append(.command("Add to \(names.joined(separator: " or "))…", isEnabled: canCopyPublicKey, action: add))
        }
        return entries
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The chevron after the Signature line's words, which opens what can be
/// done with the key that made the signature (decision 117). It's one of
/// Roga's own menus, so it opens as the mouse button goes down (decision
/// 111).
private struct SignatureMenuButton: View {
    let entries: [RefMenu.Entry]
    @State private var opener = RefMenuOpener()

    var body: some View {
        HoverIcon(size: 16) {
            Icon.dropdown.image
                .font(.system(size: 9, weight: .semibold))
        }
        .overlay { RefMenuArea(entries: entries, opensOnClick: true, opener: opener) }
        .help("Copy the key, or add it to GitHub")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Key Actions")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { opener.open() }
        .accessibilityActions { refMenuActions(entries) }
    }
}

/// Add to GitHub… from the Signature line's menu (decision 117), which says
/// where the public half of the key that made the signature can go, as New
/// SSH Key… does once it has made one (decision 108). It says whether the
/// key is one of this Mac's, since a key from another Mac is fine to add
/// when it's the person's own, and that the host also needs the commit's
/// email on the same account.
struct AddSignatureKeyPopover: View {
    let key: SignatureKey
    let format: CommitIdentity.SigningFormat
    /// The committer's email, which the host matches with an account.
    let email: String
    let session: RepositorySession
    let close: () -> Void
    @State private var found: SignaturePublicKey.Found?
    @State private var hosting: KeyHosting?
    @State private var failure: String?

    static let width: CGFloat = 320
    private static let inset: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add this key")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(key.id)
                    .font(.system(size: 12))
                    .foregroundStyle(DialogColors.note)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(EdgeInsets(top: 13, leading: Self.inset, bottom: 8, trailing: Self.inset))
            if let found {
                KeyHostsContent(
                    key: found.key,
                    hosting: hosting,
                    notes: Self.notes(found, email: email),
                    hasRepository: true,
                    add: { key, host, gh in try await session.addKey(key, to: host, gh: gh) },
                    close: close
                )
            } else if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(AgentColors.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.inset)
                DialogActionButton(button: DialogButton(title: "Done", kind: .primary, action: close))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(EdgeInsets(top: 14, leading: Self.inset, bottom: 12, trailing: Self.inset))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .padding(EdgeInsets(top: 0, leading: Self.inset, bottom: 14, trailing: Self.inset))
            }
        }
        .frame(width: Self.width)
        .font(.system(size: 13))
        // It hangs from the line's words, whose color it would otherwise
        // take, as the hierarchical .primary would too.
        .foregroundStyle(Color.primary)
        .background(DialogColors.surface)
        .task {
            do {
                found = try await session.publicKeyToAdd(key, format: format)
            } catch {
                failure = String(describing: error)
                return
            }
            hosting = await session.keyHosting()
        }
    }

    /// Whose key it is, and what else the host needs, above the hosts.
    static func notes(_ found: SignaturePublicKey.Found, email: String) -> [KeyHostsContent.Note] {
        let account = email.isEmpty ? "" : " The host also needs \(email) on the same account."
        guard found.isThisMacs else {
            return [KeyHostsContent.Note(text: "It isn't one of this Mac's keys, so add it only if it's yours, such as a key from another Mac.\(account)", isWarning: true)]
        }
        let name = found.key.shownPublicKeyFile ?? found.key.key.title
        return [KeyHostsContent.Note(text: "It's \(name), one of this Mac's keys.\(account)")]
    }
}

/// Trust This Key… under the Signature line, and the confirm it opens, which
/// says which key and which email, and shows what Roga runs and adds to the
/// allowed signers file (decisions 29 and 107).
private struct TrustKeyButton: View {
    let offer: AllowedSigners.Offer
    let session: RepositorySession
    let trusted: () -> Void
    @State private var isConfirming = false

    var body: some View {
        Button("Trust This Key…") { isConfirming = true }
            .buttonStyle(.contextual)
            .fixedSize()
            .help("Add \(offer.localKey.title) to \(offer.shownFile) for \(offer.email)")
            .popover(isPresented: $isConfirming, arrowEdge: .bottom) {
                TrustKeyPopover(offer: offer, session: session) { didTrust in
                    isConfirming = false
                    if didTrust { trusted() }
                }
            }
    }
}

struct TrustKeyPopover: View {
    let offer: AllowedSigners.Offer
    let session: RepositorySession
    let close: (_ didTrust: Bool) -> Void
    @State private var isTrusting = false
    @State private var failure: String?

    static let width: CGFloat = 300
    private static let inset: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trust this key")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("For checking the commits it signs")
                    .font(.system(size: 12))
                    .foregroundStyle(DialogColors.note)
            }
            .padding(EdgeInsets(top: 13, leading: Self.inset, bottom: 8, trailing: Self.inset))
            Text("\(offer.localKey.title) is one of this Mac's keys. Once the allowed signers file lists it for \(offer.email), git says the commits it signs are good.")
                .font(.system(size: 12))
                .foregroundStyle(DialogColors.note)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.inset)
            if let failure {
                Text(failure)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EdgeInsets(top: 8, leading: Self.inset, bottom: 0, trailing: Self.inset))
            }
            HStack(spacing: 8) {
                DialogActionButton(button: .cancel { close(false) })
                DialogActionButton(button: DialogButton(title: "Trust Key", kind: .primary, isEnabled: !isTrusting, action: trust))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(EdgeInsets(top: 14, leading: Self.inset, bottom: 12, trailing: Self.inset))
            CommandBlock(lines: Self.lines(offer), isCompact: true)
        }
        .frame(width: Self.width)
        .font(.system(size: 13))
        .background(DialogColors.surface)
    }

    /// What it runs, then the line it adds.
    static func lines(_ offer: AllowedSigners.Offer) -> [TerminalLine] {
        (offer.configArguments.map { [TerminalLine.command($0)] } ?? [])
            + [.comment("Adds this line to \(offer.shownFile)"), .output(offer.line)]
    }

    private func trust() {
        guard !isTrusting else { return }
        isTrusting = true
        failure = nil
        Task {
            do {
                try await session.trust(offer)
                close(true)
            } catch {
                failure = String(describing: error)
            }
            isTrusting = false
        }
    }
}

/// What the Signature line shows after its label, which the commit panel
/// puts in the column with the other labels (decision 109): a mark and a
/// few words on one line, then the key on a line of its own, which ends
/// with anything that follows, such as Trust This Key…. Both lines are
/// always there, so that what the check finds changes only the first
/// line's mark, color and words. Why, and who signed, are in the tooltip.
/// The words are followed by the chevron that opens the key's menu
/// (decision 117).
struct SignatureLineContent<Accessory: View, Menu: View>: View {
    let words: SignatureWords
    /// The key that made the signature, or nil while it's read, and for
    /// X.509 until the check names it.
    let key: String?
    /// What Check does, while checking is off and this commit hasn't been
    /// checked, or nil.
    var check: (() -> Void)?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var menu: Menu

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // One mark fades out as the next fades in, in the same place.
                ZStack {
                    words.icon.image
                        .font(.system(size: 12 / 1.128, weight: .medium))
                        .id(words.icon)
                        .transition(.opacity)
                }
                Text(words.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .textSelection(.enabled)
                menu
                if let check {
                    Spacer(minLength: 8)
                    Button("Check", action: check)
                        .buttonStyle(.contextual)
                        .fixedSize()
                        .help("Check this commit's signature with gpg or ssh-keygen")
                }
            }
            .foregroundStyle(words.color)
            .help(words.help ?? words.title)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // A space keeps the line's height while there's no key yet.
                Text(key ?? " ")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(key ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .contain)
    }
}

extension SignatureLineContent where Accessory == EmptyView, Menu == EmptyView {
    init(words: SignatureWords, key: String?) {
        self.init(words: words, key: key) { EmptyView() } menu: { EmptyView() }
    }
}

/// What the commit panel's Signature line says about a signed commit
/// (decisions 104 and 109): a mark and a few words that fit on one line,
/// and the longer why, and who signed, for its tooltip.
struct SignatureWords: Equatable {
    enum Tone: Equatable {
        /// Not checked yet, or nothing to worry about either way.
        case plain
        case good
        /// Good once, but not now: an expired key.
        case warning
        /// A signature that doesn't match, or a revoked key.
        case bad
    }

    var icon: Icon
    var title: String
    /// Why, or who signed, under the pointer.
    var help: String?
    var tone: Tone

    /// - Parameters:
    ///   - format: How the commit is signed, from its header.
    ///   - check: What git found, or nil before it has checked.
    ///   - email: The committer's email. A good signature from someone
    ///     else says who, since the Committer line doesn't.
    ///   - offer: Trusting the key that signed it, when it's one of this
    ///     Mac's, which the tooltip then names (decision 107).
    init(format: CommitIdentity.SigningFormat, check: SignatureCheck?, email: String = "", offer: AllowedSigners.Offer? = nil) {
        guard let check else {
            self.init(icon: .shield, title: "Signed with \(format.title)", help: nil, tone: .plain)
            return
        }
        let who = check.signer.map { "Signed by \($0)." }
        switch check.result {
        case .good:
            if let signer = check.signer, !email.isEmpty, !signer.localizedCaseInsensitiveContains(email) {
                self.init(icon: .shieldCheck, title: "Good signature from \(Self.name(signer))", help: who, tone: .good)
            } else {
                self.init(icon: .shieldCheck, title: "Good \(format.title) signature", help: who, tone: .good)
            }
        case .untrusted:
            let why = format == .ssh
                ? "The allowed signers file doesn't list \(offer.map { "\($0.localKey.title), one of this Mac's keys" } ?? "this key")."
                : "gpg doesn't trust this key enough to say whose it is."
            self.init(icon: .shieldQuestionMark, title: "Good signature, key not trusted", help: [why, who].compactMap(\.self).joined(separator: " "), tone: .plain)
        case .expired:
            self.init(icon: .shieldAlert, title: "Good signature, expired key", help: who, tone: .warning)
        case .revoked:
            self.init(icon: .shieldAlert, title: "Signed with a revoked key", help: who, tone: .bad)
        case .bad:
            self.init(icon: .shieldAlert, title: "Bad signature", help: "The signature doesn't match this commit. It was made for other contents, or with another key than it names.", tone: .bad)
        case .missingKey:
            self.init(icon: .shieldQuestionMark, title: "Signed with a key not on this Mac", help: "git can't check it without the \(format.title) key.", tone: .plain)
        case .notChecked:
            let signedWith = offer.map { " It was signed with \($0.localKey.title), one of this Mac's keys." } ?? ""
            self.init(icon: .shieldQuestionMark, title: "Signed with \(format.title), not checked", help: Self.whyNotChecked(format) + signedWith, tone: .plain)
        }
    }

    init(icon: Icon, title: String, help: String?, tone: Tone) {
        self.icon = icon
        self.title = title
        self.help = help
        self.tone = tone
    }

    /// What the line says when git couldn't be run to check.
    static func failed(_ message: String) -> SignatureWords {
        SignatureWords(icon: .shieldQuestionMark, title: "Couldn't check the signature", help: message, tone: .plain)
    }

    /// A signer's name, without the email that gpg puts after it.
    static func name(_ signer: String) -> String {
        guard let open = signer.range(of: " <") else { return signer }
        return String(signer[..<open.lowerBound])
    }

    private static func whyNotChecked(_ format: CommitIdentity.SigningFormat) -> String {
        switch format {
        case .ssh: "git needs gpg.ssh.allowedSignersFile to know whose keys to trust."
        case .openPGP: "git couldn't run gpg to check it."
        case .x509: "git couldn't run gpgsm to check it."
        }
    }

    var color: Color {
        switch tone {
        case .plain: .secondary
        case .good: Palette.green
        case .warning: AgentColors.warn
        case .bad: Palette.red
        }
    }
}
