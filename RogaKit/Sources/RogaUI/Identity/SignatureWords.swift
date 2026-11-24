import GitCore
import IconUI
import RepositoryEngine
import SwiftUI

/// The commit panel's line under the author for a signed commit, which
/// checks the signature in the background as the commit shows (decision 104).
/// It waits a moment first, so that moving through history with the arrow
/// keys doesn't run gpg or ssh-keygen for every commit on the way, and a
/// check that's still running stops when another commit shows.
struct SignatureLine: View {
    let commit: ObjectID
    let format: CommitIdentity.SigningFormat
    let session: RepositorySession
    /// What the check found, and for which commit, so that a line that's
    /// reused for the next commit doesn't show the last one's.
    @State private var found: (commit: ObjectID, words: SignatureWords)?

    /// How long a commit shows before its signature is checked.
    static let pause = Duration.milliseconds(150)

    var body: some View {
        SignatureLineContent(words: found.flatMap { $0.commit == commit ? $0.words : nil } ?? SignatureWords(format: format, check: nil))
            .task(id: commit) {
                guard (try? await Task.sleep(for: Self.pause)) != nil else { return }
                let words: SignatureWords
                do {
                    words = SignatureWords(format: format, check: try await session.checkSignature(of: commit))
                } catch {
                    guard !Task.isCancelled else { return }
                    words = .failed(String(describing: error))
                }
                guard !Task.isCancelled else { return }
                found = (commit, words)
            }
    }
}

/// What the Signature line looks like: its label, then a mark and the words,
/// with the gray detail under them.
struct SignatureLineContent: View {
    let words: SignatureWords

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Signature")
                .foregroundStyle(.secondary)
            Text("  ")
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
                }
                .foregroundStyle(words.color)
                if let detail = words.detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
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
    init(format: CommitIdentity.SigningFormat, check: SignatureCheck?) {
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
