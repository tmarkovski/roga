import GitCore
import IconUI
import RepositoryEngine
import SwiftUI

/// The commit panel's line under the author for a signed commit, which
/// checks the signature in the background as the commit shows (decision 104).
/// It waits a moment first, so that moving through history with the arrow
/// keys doesn't run gpg or ssh-keygen for every commit on the way, and a
/// check that's still running stops when another commit shows. When git
/// couldn't vouch for an SSH signature made with one of this Mac's keys, it
/// offers to trust the key (decision 107).
struct SignatureLine: View {
    let commit: ObjectID
    let format: CommitIdentity.SigningFormat
    /// The committer's email, which trusting the key is for.
    let email: String
    let session: RepositorySession
    /// What the check found, and for which commit, so that a line that's
    /// reused for the next commit doesn't show the last one's.
    @State private var found: Found?
    /// How many times a key has been trusted here, so that the commit is
    /// checked again after each.
    @State private var trusts = 0

    struct Found: Equatable {
        var commit: ObjectID
        var words: SignatureWords
        var offer: AllowedSigners.Offer?
    }

    /// What starts a check: another commit, or a key just trusted.
    private struct Check: Hashable {
        var commit: ObjectID
        var trusts: Int
    }

    /// How long a commit shows before its signature is checked.
    static let pause = Duration.milliseconds(150)

    var body: some View {
        let shown = found?.commit == commit ? found : nil
        SignatureLineContent(words: shown?.words ?? SignatureWords(format: format, check: nil)) {
            if let offer = shown?.offer {
                TrustKeyButton(offer: offer, session: session) { trusts += 1 }
            }
        }
        .task(id: Check(commit: commit, trusts: trusts)) {
            // A check after trusting a key needn't wait.
            if trusts == 0 || found?.commit != commit {
                guard (try? await Task.sleep(for: Self.pause)) != nil else { return }
            }
            let check: SignatureCheck
            do {
                check = try await session.checkSignature(of: commit)
            } catch {
                guard !Task.isCancelled else { return }
                found = Found(commit: commit, words: .failed(String(describing: error)))
                return
            }
            guard !Task.isCancelled else { return }
            found = Found(commit: commit, words: SignatureWords(format: format, check: check))
            // Only an SSH signature waits on the allowed signers file.
            guard format == .ssh, [.notChecked, .untrusted].contains(check.result),
                  let offer = await session.allowedSignersOffer(for: commit, email: email),
                  !Task.isCancelled
            else { return }
            found = Found(commit: commit, words: SignatureWords(format: format, check: check, offer: offer), offer: offer)
        }
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
            .padding(.top, 2)
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
/// puts in the column with the other labels: a mark and the words, with the
/// gray detail under them, and anything that follows, such as Trust This
/// Key….
struct SignatureLineContent<Accessory: View>: View {
    let words: SignatureWords
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let icon = words.icon {
                    icon.image
                        .font(.system(size: 12 / 1.128, weight: .medium))
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(words.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .foregroundStyle(words.color)
            if let detail = words.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            accessory
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .contain)
    }
}

extension SignatureLineContent where Accessory == EmptyView {
    init(words: SignatureWords) {
        self.init(words: words) { EmptyView() }
    }
}

/// What the commit panel's Signature line says about a signed commit
/// (decision 104): a mark and a few words, then a gray line with who signed
/// it and with what key, or why git couldn't tell.
struct SignatureWords: Equatable {
    enum Tone: Equatable {
        /// Checking, or nothing to worry about either way.
        case plain
        case good
        /// Good once, but not now: an expired key.
        case warning
        /// A signature that doesn't match, or a revoked key.
        case bad
    }

    var icon: Icon?
    var title: String
    var detail: String?
    var tone: Tone

    /// - Parameters:
    ///   - format: How the commit is signed, from its header.
    ///   - check: What git found, or nil while it checks.
    ///   - offer: Trusting the key that signed it, when it's one of this
    ///     Mac's, which the detail then names (decision 107).
    init(format: CommitIdentity.SigningFormat, check: SignatureCheck?, offer: AllowedSigners.Offer? = nil) {
        self.init(checked: format, check: check)
        guard let offer, let check else { return }
        let key = "\(offer.localKey.title), one of this Mac's keys"
        switch check.result {
        case .notChecked: detail = "\(Self.whyNotChecked(format)) It was signed with \(key)."
        case .untrusted: detail = "The allowed signers file doesn't list \(key)."
        default: break
        }
    }

    private init(checked format: CommitIdentity.SigningFormat, check: SignatureCheck?) {
        guard let check else {
            self.init(icon: nil, title: "Checking…", detail: nil, tone: .plain)
            return
        }
        let who = [check.signer, check.key].compactMap(\.self).joined(separator: " · ")
        let whoOrNil = who.isEmpty ? nil : who
        switch check.result {
        case .good:
            self.init(icon: .shieldCheck, title: "Good \(format.title) signature", detail: whoOrNil, tone: .good)
        case .untrusted:
            let detail = format == .ssh
                ? ["The allowed signers file doesn't list this key.", check.key].compactMap(\.self).joined(separator: " ")
                : whoOrNil
            self.init(icon: .shieldQuestionMark, title: "Good signature, from a key this Mac doesn't trust", detail: detail, tone: .plain)
        case .expired:
            self.init(icon: .shieldAlert, title: "Good signature, from a key that has expired", detail: whoOrNil, tone: .warning)
        case .revoked:
            self.init(icon: .shieldAlert, title: "Signed with a key that has been revoked", detail: whoOrNil, tone: .bad)
        case .bad:
            self.init(icon: .shieldAlert, title: "The signature doesn't match this commit", detail: "It was made for other contents, or with another key than it names.", tone: .bad)
        case .missingKey:
            self.init(icon: .shieldQuestionMark, title: "Signed with a key this Mac doesn't have", detail: check.key.map { "\(format.title) key \($0)" }, tone: .plain)
        case .notChecked:
            self.init(icon: .shieldQuestionMark, title: "Signed with \(format.title), not checked", detail: Self.whyNotChecked(format), tone: .plain)
        }
    }

    init(icon: Icon?, title: String, detail: String?, tone: Tone) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.tone = tone
    }

    /// What the line says when git couldn't be run to check.
    static func failed(_ message: String) -> SignatureWords {
        SignatureWords(icon: .shieldQuestionMark, title: "Couldn't check the signature", detail: message, tone: .plain)
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
