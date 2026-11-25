import Foundation
import GitCore
import IconUI
import RepositoryEngine
import SwiftUI

/// The Key field of the identity popover and Settings › Git, which offers the
/// keys this Mac has for the format in a menu at its end (decision 106). A
/// path or key ID that isn't listed can still be typed. The line under it
/// says which key the field names, or why the menu has none.
struct SigningKeyField: View {
    @Binding var text: String
    let format: CommitIdentity.SigningFormat
    /// The keys for the format, or nil while they're being listed and for
    /// X.509, which has no list.
    let listing: SigningKeys.Listing?
    /// The identity's email, whose keys come first.
    let email: String?
    /// Whether `gpg.ssh.defaultKeyCommand` is set, so that no key at all
    /// lets it pick one.
    let hasDefaultKeyCommand: Bool
    let width: CGFloat
    /// The focus Settings follows, to save a field when it's left.
    var focus: FocusState<CommitIdentityCommands.Key?>.Binding?
    /// What choosing a key from the menu does after filling the field, which
    /// in Settings is saving it.
    var choose: (String) -> Void = { _ in }

    var body: some View {
        let keys = listing.map { SigningKeys.ordered($0.keys, for: email) } ?? []
        let offersDefault = hasDefaultKeyCommand && format == .ssh
        VStack(alignment: .leading, spacing: 4) {
            focused(SettingsTextField(text: $text, placeholder: placeholder, width: width, isMonospaced: true, trailingRoom: keys.isEmpty && !offersDefault ? 0 : 22))
                .accessibilityLabel("Key")
                .overlay(alignment: .trailing) {
                    if !keys.isEmpty || offersDefault {
                        menu(keys, offersDefault: offersDefault)
                            .padding(.trailing, 5)
                    }
                }
            if let line = line(keys) {
                Text(line)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DialogColors.note)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width, alignment: .leading)
            }
        }
    }

    private func menu(_ keys: [SigningKey], offersDefault: Bool) -> some View {
        Menu {
            if offersDefault {
                Button {
                    pick("")
                } label: {
                    Text("Whatever gpg.ssh.defaultKeyCommand Picks")
                    Text("Leaves user.signingkey unset")
                }
                if !keys.isEmpty { Divider() }
            }
            ForEach(keys) { key in
                Button {
                    pick(key.value)
                } label: {
                    Text(key.title)
                    Text(key.subtitle)
                }
            }
        } label: {
            Icon.chevronsUpDown.image
                .font(.system(size: 12 / 1.128, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Keys on This Mac")
        .accessibilityLabel("Keys on This Mac")
    }

    @ViewBuilder private func focused(_ field: some View) -> some View {
        if let focus {
            field.focused(focus, equals: .signingKey)
        } else {
            field
        }
    }

    private func pick(_ value: String) {
        text = value
        choose(value)
    }

    private var placeholder: String {
        switch format {
        case .ssh: hasDefaultKeyCommand ? "Empty to let gpg.ssh.defaultKeyCommand pick" : "~/.ssh/id_ed25519.pub"
        case .openPGP: "Key ID, or empty to use the email's"
        case .x509: "Certificate ID, or empty to use the email's"
        }
    }

    /// Which listed key the field names, or why there are none to offer.
    private func line(_ keys: [SigningKey]) -> String? {
        if let key = Self.key(named: text, in: keys) {
            return key.title == key.value ? key.subtitle : "\(key.title) · \(key.subtitle)"
        }
        return listing?.emptyReason
    }

    /// The listed key a field's text names: the same path, with or without
    /// `~`, the same `key::` key, or an OpenPGP fingerprint that ends with
    /// the key ID typed, without case or spaces.
    static func key(named text: String, in keys: [SigningKey]) -> SigningKey? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return nil }
        let expanded = (typed as NSString).expandingTildeInPath
        if let key = keys.first(where: { $0.value == typed || ($0.value as NSString).expandingTildeInPath == expanded }) {
            return key
        }
        let hex = typed.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "0X", with: "")
        guard hex.count >= 8, hex.allSatisfy(\.isHexDigit) else { return nil }
        return keys.first { $0.fingerprint.uppercased().hasSuffix(hex) }
    }
}
