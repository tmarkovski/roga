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
/// 108). First it says what Roga makes, and shows what it runs, as decision
/// 29 asks. Once the key is made, it says where the key's public half can
/// go so that the commits it signs show as verified: Add to GitHub runs gh
/// when gh may add keys there, and otherwise Open GitHub or Open GitLab
/// goes to the host's page, with Copy Public Key for pasting it there or
/// anywhere else.
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
    @State private var added: Set<KeyHost> = []
    @State private var adding: KeyHost?
    @State private var hasCopied = false
    @Environment(\.openURL) private var openURL

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
            header("New \(format.title) key", sub: "For signing commits as \(email)")
            Group {
                switch planned {
                case nil:
                    ProgressView().controlSize(.small)
                case .ready(let plan):
                    Text(Self.note(plan))
                        .foregroundStyle(DialogColors.note)
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

    /// What the confirm says Roga makes.
    static func note(_ plan: NewSigningKey.Plan) -> String {
        let unguarded = "without a passphrase, so git, Roga and agents can sign without asking"
        switch plan.format {
        case .ssh:
            let file = plan.shownFile ?? "~/.ssh"
            let trust = plan.trust.map { " It also goes in \($0.shownFile), so git says your commits are good." } ?? ""
            return "Roga makes an Ed25519 key in \(file), \(unguarded). Anyone who can read that file can sign as you.\(trust)"
        case .openPGP, .x509:
            return "Roga makes an Ed25519 key for \(plan.userID) that doesn't expire, \(unguarded). Anyone who can use your GnuPG keyring can sign as you."
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
            VStack(alignment: .leading, spacing: 10) {
                Text(maker.savesAtOnce ? "Commits are signed with it now." : "It's in the Key field. Save to sign commits with it.")
                    .foregroundStyle(DialogColors.note)
                if let trustFailure = made.trustFailure {
                    Text("Roga couldn't add it to the allowed signers file: \(trustFailure)")
                        .foregroundStyle(AgentColors.warn)
                }
                if let hosting {
                    if hosting.hosts.isEmpty {
                        Text(maker.repository == nil
                            ? "Copy Public Key copies it, for adding it wherever you push, so that commits show as verified there."
                            : "None of this repository's remotes is on GitHub or GitLab. Copy Public Key copies it, for adding it wherever you push.")
                            .foregroundStyle(DialogColors.note)
                    }
                    ForEach(hosting.hosts) { host in
                        hostRow(host, made: made, hosting: hosting)
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Looking for gh…").foregroundStyle(DialogColors.note)
                    }
                }
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Self.inset)
            failureLine
            HStack(spacing: 8) {
                DialogActionButton(button: DialogButton(title: hasCopied ? "Copied" : "Copy Public Key", kind: .secondary) { copy(made) })
                DialogActionButton(button: DialogButton(title: "Done", kind: .primary, action: close))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(EdgeInsets(top: 14, leading: Self.inset, bottom: 12, trailing: Self.inset))
            CommandBlock(lines: hosting.map { Self.lines(made, hosting: $0, added: added) } ?? [.blank], isCompact: true)
        }
    }

    /// A host's line: what happens there, and Add to GitHub, or the button
    /// that opens its page.
    private func hostRow(_ host: KeyHost, made: NewSigningKey.Made, hosting: KeyHosting) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(host.name) · \(host.host)")
                    .font(.system(size: 12, weight: .semibold))
                Text(Self.hostWords(host, format: made.format, hosting: hosting, isAdded: added.contains(host)))
                    .foregroundStyle(DialogColors.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if added.contains(host) {
                Icon.check.image
                    .foregroundStyle(Palette.green)
                    .accessibilityLabel("Added")
            } else if let gh = hosting.gh, hosting.canAdd(made.format, to: host) {
                Button(adding == host ? "Adding…" : "Add to \(host.name)") { add(made, to: host, gh: gh) }
                    .buttonStyle(.outlined)
                    .disabled(adding != nil)
                    .fixedSize()
            } else if let page = host.page(for: made.format) {
                Button("Open \(host.name)") {
                    copy(made)
                    openURL(page)
                }
                .buttonStyle(.outlined)
                .fixedSize()
                .help("Copies the public key and opens \(page.absoluteString)")
            }
        }
    }

    /// What a host's line says.
    static func hostWords(_ host: KeyHost, format: CommitIdentity.SigningFormat, hosting: KeyHosting, isAdded: Bool) -> String {
        let verified = "so commits signed with it show as Verified"
        if isAdded { return "Added as a signing key, \(verified)." }
        switch host {
        case .gitHub:
            let kind = format == .ssh ? "a signing key" : "a GPG key"
            if hosting.canAdd(format, to: host) { return "gh can add it as \(kind), \(verified)." }
            if hosting.gh != nil, hosting.account(on: host) != nil {
                return "gh may not add \(format == .ssh ? "signing keys" : "GPG keys") yet. Run the command below once, or add it on GitHub as \(kind), \(verified)."
            }
            return "Add it on GitHub as \(kind), \(verified). Open GitHub copies it first."
        case .gitLab:
            let usage = format == .ssh ? " with the usage type Signing" : ""
            return "Add it on GitLab\(usage), \(verified). Open GitLab copies it first."
        }
    }

    /// What adding the key runs, and for a GitHub host gh may not add keys
    /// to, the one command that lets it.
    static func lines(_ made: NewSigningKey.Made, hosting: KeyHosting, added: Set<KeyHost>) -> [TerminalLine] {
        var lines: [TerminalLine] = []
        for host in hosting.hosts where !added.contains(host) {
            guard case .gitHub(let name) = host, let gh = hosting.gh else { continue }
            if hosting.canAdd(made.format, to: host) {
                if made.format != .ssh { lines.append(.comment("Add to GitHub pipes in gpg --armor --export \(made.key.fingerprint)")) }
                var command = ProgramCommand(gh, GitHubCLI.addArguments(made, title: GitHubCLI.title))
                if name != "github.com" { command.environment["GH_HOST"] = name }
                lines.append(.program(command))
            } else if hosting.account(on: host) != nil {
                lines.append(.comment("Lets gh add keys to \(name). Run it once in Terminal."))
                lines.append(.program(ProgramCommand(gh, GitHubCLI.refreshArguments(host: name, format: made.format))))
            }
        }
        if lines.isEmpty {
            lines.append(.comment("Copy Public Key copies \(made.shownPublicKeyFile ?? "the public key")"))
        }
        return lines
    }

    private func add(_ made: NewSigningKey.Made, to host: KeyHost, gh: String) {
        adding = host
        failure = nil
        Task {
            do {
                try await maker.list.addKey(made, to: host, gh: gh)
                added.insert(host)
            } catch {
                failure = String(describing: error)
            }
            adding = nil
        }
    }

    private func copy(_ made: NewSigningKey.Made) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(made.publicKey, forType: .string)
        hasCopied = true
    }

    // MARK: Parts

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
