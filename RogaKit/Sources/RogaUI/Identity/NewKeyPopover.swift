import AppKit
import GitCore
import GitRunner
import IconUI
import RepositoryEngine
import SwiftUI

/// What the Key field needs to offer New SSH Key… and New OpenPGP Key…
/// (decision 108).
struct KeyMaker {
    let list: RepositoryList
    /// The repository whose config names the programs, or nil in Settings,
    /// which uses the global config.
    let repository: ListedRepository?
    /// The identity's name, for an OpenPGP key's user ID.
    let name: String
    /// Whether choosing a key saves it at once, as Settings does, rather
    /// than when the popover's Save is pressed.
    let savesAtOnce: Bool
    /// What the field's owner does with a key once it's made, such as adding
    /// it to the menu's list.
    var made: (NewSigningKey.Made) -> Void = { _ in }
}

/// New SSH Key… or New OpenPGP Key… from the Key field's menu (decision
/// 108). First it says what Roga makes, with the name and email the key is
/// for in a card of their own, and shows what it runs, as decision 29 asks.
/// Once the key is made, it says where the key's public half can go so that
/// the commits it signs show as verified, as `KeyHostsContent` lays out.
struct NewKeyPopover: View {
    let format: CommitIdentity.SigningFormat
    let email: String
    let maker: KeyMaker
    let made: (NewSigningKey.Made) -> Void
    let close: () -> Void

    @State private var planned: NewSigningKey.Planned?
    @State private var isMaking = false
    @State private var failure: String?
    @State private var result: NewSigningKey.Made?
    @State private var hosting: KeyHosting?

    static let width: CGFloat = 320
    private static let inset: CGFloat = 16

    /// - Parameters:
    ///   - planned, result, hosting: Where to start, for drawing the popover
    ///     partway, or nil to start from the confirm and look up the plan.
    init(
        format: CommitIdentity.SigningFormat,
        email: String,
        maker: KeyMaker,
        planned: NewSigningKey.Planned? = nil,
        result: NewSigningKey.Made? = nil,
        hosting: KeyHosting? = nil,
        made: @escaping (NewSigningKey.Made) -> Void,
        close: @escaping () -> Void
    ) {
        self.format = format
        self.email = email
        self.maker = maker
        self.made = made
        self.close = close
        _planned = State(initialValue: planned)
        _result = State(initialValue: result)
        _hosting = State(initialValue: hosting)
    }

    var body: some View {
        Group {
            if let result {
                madeContent(result)
            } else {
                confirmContent
            }
        }
        .frame(width: Self.width)
        .font(.system(size: 13))
        .background(DialogColors.surface)
    }

    // MARK: Before

    private var confirmContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("New \(format.title) key", sub: "For signing commits")
            Group {
                switch planned {
                case nil:
                    ProgressView().controlSize(.small)
                case .ready(let plan):
                    VStack(alignment: .leading, spacing: 10) {
                        factsCard(plan)
                        Text(Self.note(plan))
                            .foregroundStyle(DialogColors.note)
                    }
                case .unavailable(let reason):
                    Text(reason)
                        .foregroundStyle(AgentColors.warn)
                }
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Self.inset)
            failureLine
            HStack(spacing: 8) {
                DialogActionButton(button: .cancel(close))
                DialogActionButton(button: DialogButton(title: "Make Key", kind: .primary, isEnabled: plan != nil && !isMaking, action: make))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(EdgeInsets(top: 14, leading: Self.inset, bottom: 12, trailing: Self.inset))
            CommandBlock(lines: plan.map(Self.lines) ?? [.blank], isCompact: true)
        }
        .task {
            guard planned == nil else { return }
            planned = await maker.list.newKeyPlan(format, name: maker.name, email: email, for: maker.repository)
        }
    }

    private var plan: NewSigningKey.Plan? {
        if case .ready(let plan) = planned { return plan }
        return nil
    }

    /// A line of the card above the note, as in `Email` and
    /// `sam@rivera.dev`.
    struct Fact: Equatable {
        let label: String
        let value: String
    }

    /// Who the key is for, and where a new SSH key goes, in the card above
    /// the note, so that the name and email it's made with are plain before
    /// it's made. An SSH key keeps only the email, as its comment.
    static func facts(_ plan: NewSigningKey.Plan) -> [Fact] {
        var facts: [Fact] = []
        if !plan.name.isEmpty { facts.append(Fact(label: "Name", value: plan.name)) }
        facts.append(Fact(label: "Email", value: plan.email))
        if let file = plan.shownFile { facts.append(Fact(label: "File", value: file)) }
        return facts
    }

    /// What the confirm says Roga makes.
    static func note(_ plan: NewSigningKey.Plan) -> String {
        let unguarded = "without a passphrase, so git, Roga and agents can sign without asking"
        switch plan.format {
        case .ssh:
            let trust = plan.trust.map { " It also goes in \($0.shownFile), so git says your commits are good." } ?? ""
            return "Roga makes an Ed25519 key \(unguarded). Anyone who can read the file can sign as you.\(trust)"
        case .openPGP, .x509:
            return "Roga makes an Ed25519 key that doesn't expire, \(unguarded). Anyone who can use your GnuPG keyring can sign as you."
        }
    }

    /// What making the key runs, then, for SSH, what trusting it runs and
    /// adds (decision 107).
    static func lines(_ plan: NewSigningKey.Plan) -> [TerminalLine] {
        var lines: [TerminalLine] = [.program(plan.command)]
        if let trust = plan.trust {
            if let arguments = trust.configArguments { lines.append(.command(arguments)) }
            lines.append(.comment("Adds the new key to \(trust.shownFile) for \(plan.email)"))
        }
        return lines
    }

    private func make() {
        guard let plan, !isMaking else { return }
        isMaking = true
        failure = nil
        Task {
            do {
                let key = try await maker.list.makeKey(plan, for: maker.repository)
                result = key
                made(key)
                hosting = await maker.list.keyHosting(for: maker.repository)
            } catch {
                failure = String(describing: error)
            }
            isMaking = false
        }
    }

    // MARK: After

    private func madeContent(_ made: NewSigningKey.Made) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Key made", sub: made.shownPublicKeyFile ?? made.key.title)
            KeyHostsContent(
                key: made,
                hosting: hosting,
                notes: Self.madeNotes(made, savesAtOnce: maker.savesAtOnce),
                hasRepository: maker.repository != nil,
                add: { key, host, gh in try await maker.list.addKey(key, to: host, gh: gh) },
                close: close
            )
        }
    }

    /// What the popover says once the key is made, above the hosts.
    static func madeNotes(_ made: NewSigningKey.Made, savesAtOnce: Bool) -> [KeyHostsContent.Note] {
        var notes = [KeyHostsContent.Note(text: savesAtOnce ? "Commits are signed with it now." : "It's in the Key field. Save to sign commits with it.")]
        if let trustFailure = made.trustFailure {
            notes.append(KeyHostsContent.Note(text: "Roga couldn't add it to the allowed signers file: \(trustFailure)", isWarning: true))
        }
        return notes
    }

    // MARK: Parts

    /// The name and email the key is made for, and an SSH key's file, with
    /// the values in the text's color so that they stand out from the note.
    private func factsCard(_ plan: NewSigningKey.Plan) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Self.facts(plan), id: \.label) { fact in
                GridRow {
                    Text(fact.label)
                        .font(.system(size: 12))
                        .foregroundStyle(DialogColors.note)
                    Text(verbatim: fact.value)
                        .font(.system(size: 13, weight: .medium))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DialogColors.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func header(_ title: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(sub)
                .font(.system(size: 12))
                .foregroundStyle(DialogColors.note)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(EdgeInsets(top: 13, leading: Self.inset, bottom: 8, trailing: Self.inset))
    }

    @ViewBuilder private var failureLine: some View {
        if let failure {
            Text(failure)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 8, leading: Self.inset, bottom: 0, trailing: Self.inset))
        }
    }
}
