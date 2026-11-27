import AppKit
import GitCore
import GitRunner
import IconUI
import RepositoryEngine
import SwiftUI

/// Where a key's public half can go so that the commits it signs show as
/// verified (decision 108), under a popover's header: Add to GitHub runs gh
/// when gh may add keys there, and otherwise Open GitHub or Open GitLab goes
/// to the host's page, with Copy Public Key for pasting it there or anywhere
/// else. New SSH Key… and New OpenPGP Key… show it once the key is made, and
/// the Signature line's Add to GitHub… shows it for the key that signed the
/// commit (decision 117).
struct KeyHostsContent: View {
    /// A line above the hosts, such as what happened to a new key.
    struct Note: Hashable {
        var text: String
        var isWarning = false
    }

    let key: NewSigningKey.Made
    /// The hosts and gh, or nil while they're looked up.
    let hosting: KeyHosting?
    let notes: [Note]
    /// What it says when no remote is on GitHub or GitLab, which differs in
    /// Settings, where there's no repository.
    let hasRepository: Bool
    let add: (NewSigningKey.Made, KeyHost, _ gh: String) async throws -> Void
    let close: () -> Void

    @State private var added: Set<KeyHost> = []
    @State private var adding: KeyHost?
    @State private var hasCopied = false
    @State private var failure: String?
    @Environment(\.openURL) private var openURL

    static let inset: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(notes, id: \.self) { note in
                    Text(note.text)
                        .foregroundStyle(note.isWarning ? AgentColors.warn : DialogColors.note)
                }
                if let hosting {
                    if hosting.hosts.isEmpty {
                        Text(hasRepository
                            ? "Copy the public key to add it to your Git hosting account."
                            : "Copy Public Key copies it, for adding it wherever you push, so that commits show as verified there.")
                            .foregroundStyle(DialogColors.note)
                    }
                    ForEach(hosting.hosts) { host in
                        hostRow(host, hosting: hosting)
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
            if let failure {
                Text(failure)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EdgeInsets(top: 8, leading: Self.inset, bottom: 0, trailing: Self.inset))
            }
            HStack(spacing: 8) {
                DialogActionButton(button: DialogButton(title: hasCopied ? "Copied" : "Copy Public Key", kind: .secondary, action: copy))
                DialogActionButton(button: DialogButton(title: "Done", kind: .primary, action: close))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(EdgeInsets(top: 14, leading: Self.inset, bottom: 12, trailing: Self.inset))
            CommandBlock(lines: hosting.map { Self.lines(key, hosting: $0, added: added) } ?? [.blank], isCompact: true)
        }
    }

    /// A host's line: what happens there, and Add to GitHub, or the button
    /// that opens its page.
    private func hostRow(_ host: KeyHost, hosting: KeyHosting) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(host.name) · \(host.host)")
                    .font(.system(size: 12, weight: .semibold))
                Text(Self.hostWords(host, format: key.format, hosting: hosting, isAdded: added.contains(host)))
                    .foregroundStyle(DialogColors.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if added.contains(host) {
                Icon.check.image
                    .foregroundStyle(Palette.green)
                    .accessibilityLabel("Added")
            } else if let gh = hosting.gh, hosting.canAdd(key.format, to: host) {
                Button(adding == host ? "Adding…" : "Add to \(host.name)") { add(to: host, gh: gh) }
                    .buttonStyle(.outlined)
                    .disabled(adding != nil)
                    .fixedSize()
            } else if let page = host.page(for: key.format) {
                Button("Open \(host.name)") {
                    copy()
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
            return "Open GitHub copies the public key and opens your key settings. Add it as \(kind), \(verified)."
        case .gitLab:
            let usage = format == .ssh ? " with the usage type Signing" : ""
            return "Open GitLab copies the public key and opens your key settings. Add the key\(usage), \(verified)."
        }
    }

    /// What adding the key runs, and for a GitHub host gh may not add keys
    /// to, the one command that lets it.
    static func lines(_ key: NewSigningKey.Made, hosting: KeyHosting, added: Set<KeyHost>) -> [TerminalLine] {
        var lines: [TerminalLine] = []
        for host in hosting.hosts where !added.contains(host) {
            guard case .gitHub(let name) = host, let gh = hosting.gh else { continue }
            if hosting.canAdd(key.format, to: host) {
                if key.format != .ssh {
                    lines.append(.comment("Add to GitHub pipes in gpg --armor --export \(key.key.fingerprint)"))
                } else if key.publicKeyFile == nil {
                    lines.append(.comment("Add to GitHub pipes in the public key"))
                }
                var command = ProgramCommand(gh, GitHubCLI.addArguments(key, title: GitHubCLI.title))
                if name != "github.com" { command.environment["GH_HOST"] = name }
                lines.append(.program(command))
            } else if hosting.account(on: host) != nil {
                lines.append(.comment("Lets gh add keys to \(name). Run it once in Terminal."))
                lines.append(.program(ProgramCommand(gh, GitHubCLI.refreshArguments(host: name, format: key.format))))
            }
        }
        if lines.isEmpty {
            lines.append(.comment("Copy Public Key copies \(key.shownPublicKeyFile ?? "the public key")"))
        }
        return lines
    }

    private func add(to host: KeyHost, gh: String) {
        adding = host
        failure = nil
        Task {
            do {
                try await add(key, host, gh)
                added.insert(host)
            } catch {
                failure = String(describing: error)
            }
            adding = nil
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKey, forType: .string)
        hasCopied = true
    }
}
