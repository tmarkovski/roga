import Foundation
import GitCore
import IconUI
import RepositoryEngine
import SwiftUI

/// The Key field of the identity popover and Settings › Git (decision 106).
/// The chevron at its end opens the keys this Mac has for the format, as
/// cards with a radio, and a path or key ID that isn't listed can still be
/// typed. The line under it says which key the field names, or why there
/// are none. New SSH Key… or New OpenPGP Key…, in the accent color, ends the
/// field's label where it has one over it, as in the identity popover, and
/// the line under it otherwise, as in Settings (decision 108).
struct SigningKeyField<Label: View>: View {
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
    /// What picking a key does after filling the field, which in Settings
    /// is saving it.
    var choose: (String) -> Void = { _ in }
    /// What New SSH Key… and New OpenPGP Key… need, or nil to offer neither
    /// (decision 108).
    var maker: KeyMaker?
    /// The label over the field, which New Key… ends, or nil where the
    /// field has its name beside it, as in Settings. Under a label, the line
    /// about the key always has room for two lines, so that picking a key
    /// doesn't change how tall the field is.
    var label: Label?
    /// Set from when the keys or New Key… open over the field until they've
    /// finished closing, which the identity popover follows to keep its
    /// height meanwhile.
    var isShowingPopover: Binding<Bool>?
    @State private var isPicking = false
    @State private var isMakingKey = false

    var body: some View {
        let keys = listing.map { SigningKeys.ordered($0.keys, for: email) } ?? []
        let offersDefault = hasDefaultKeyCommand && format == .ssh
        let hasPicker = !keys.isEmpty || offersDefault
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                HStack(spacing: 12) {
                    label
                    newKeyButton
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                field(keys, offersDefault: offersDefault, hasPicker: hasPicker)
                lineUnder(keys)
            }
        }
        .onChange(of: isPicking || isMakingKey) { _, isOpen in
            if isOpen { isShowingPopover?.wrappedValue = true }
        }
        // The keys or New Key… are gone once AppKit says their popover has
        // closed, which is after its closing has run. Their content goes as
        // the closing starts, and a popover under one that's still closing
        // drew a frame out of place when it took its new height then. Only
        // they close while the field asks for neither.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            if !isPicking, !isMakingKey { isShowingPopover?.wrappedValue = false }
        }
        .task(id: isPicking || isMakingKey) {
            // In case AppKit says nothing, such as when one closes before
            // the field knows it has.
            guard !isPicking, !isMakingKey, isShowingPopover?.wrappedValue == true else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { isShowingPopover?.wrappedValue = false }
        }
    }

    private func field(_ keys: [SigningKey], offersDefault: Bool, hasPicker: Bool) -> some View {
        focused(SettingsTextField(text: $text, placeholder: placeholder, width: width, isMonospaced: true, trailingRoom: hasPicker ? 22 : 0))
            .accessibilityLabel("Key")
            .overlay(alignment: .trailing) {
                if hasPicker {
                    pickerButton(keys, offersDefault: offersDefault)
                        .padding(.trailing, 4)
                }
            }
            .popover(isPresented: $isMakingKey, arrowEdge: .bottom) {
                if let maker {
                    NewKeyPopover(format: format, email: email ?? "", maker: maker, made: made) {
                        isMakingKey = false
                    }
                }
            }
            // In Settings, the row's words line up with the field, and
            // the line about the key hangs under it.
            .alignmentGuide(.settingsRowMiddle) { $0[VerticalAlignment.center] }
    }

    /// The line about the key under the field.
    @ViewBuilder private func lineUnder(_ keys: [SigningKey]) -> some View {
        let line = line(keys)
        if label != nil {
            // Two lines' room from the start, whatever the line says and
            // whether the keys have been listed yet, so that nothing under
            // it moves.
            ZStack(alignment: .topLeading) {
                lineText(" \n ").hidden()
                lineText(line)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
        } else if line != nil || offersNewKey {
            // Side by side when the line fits on one row beside the
            // button, and otherwise the line keeps the whole width and
            // the button goes under it, so that a long user ID isn't cut.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    lineText(line).fixedSize()
                    Spacer(minLength: 0)
                    newKeyButton
                }
                VStack(alignment: .trailing, spacing: 3) {
                    lineText(line)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    newKeyButton
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    private func lineText(_ line: String?) -> some View {
        Text(line ?? "")
            .font(.system(size: 11.5))
            .foregroundStyle(DialogColors.note)
    }

    /// In the accent, as Use Global and Trust This Key… are, so that it
    /// shows even when there are no keys to pick (decision 108).
    @ViewBuilder private var newKeyButton: some View {
        if offersNewKey {
            Button("New \(format.title) Key…") { isMakingKey = true }
                .buttonStyle(.contextual)
                .fixedSize()
                .help("Make an Ed25519 key without a passphrase")
        }
    }

    /// The chevron at the field's end, which opens the keys as cards.
    private func pickerButton(_ keys: [SigningKey], offersDefault: Bool) -> some View {
        Button {
            isPicking.toggle()
        } label: {
            // A gray square under the pointer, as history's Order menu gets.
            HoverIcon(isPressed: isPicking, size: 24) {
                Icon.chevronsUpDown.image
                    .font(.system(size: 12 / 1.128, weight: .medium))
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .opensOnPress($isPicking)
        .help("Keys on This Mac")
        .accessibilityLabel("Keys on This Mac")
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            KeyPickerPopover(
                format: format,
                keys: keys,
                picked: SigningKeys.key(named: text, in: keys),
                offersDefault: offersDefault,
                isEmpty: text.trimmingCharacters(in: .whitespaces).isEmpty,
                savesAtOnce: maker?.savesAtOnce ?? false,
                pick: pick
            ) {
                isPicking = false
            }
        }
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

    /// Whether New Key… shows: for SSH and OpenPGP, once the keys have been
    /// listed.
    private var offersNewKey: Bool {
        maker != nil && format != .x509 && listing != nil
    }

    /// A new key goes in the field, as one picked from the list does, and
    /// its owner adds it to the list.
    private func made(_ key: NewSigningKey.Made) {
        maker?.made(key)
        pick(key.key.value)
    }

    private var placeholder: String {
        switch format {
        case .ssh: hasDefaultKeyCommand ? "Leave blank to use Git's default SSH key command" : "~/.ssh/id_ed25519.pub"
        case .openPGP: "Key ID, or leave blank to match your email"
        case .x509: "Certificate ID, or leave blank to match your email"
        }
    }

    /// Which listed key the field names, or why there are none to offer.
    private func line(_ keys: [SigningKey]) -> String? {
        if let key = SigningKeys.key(named: text, in: keys) {
            return key.title == key.value ? key.subtitle : "\(key.title) · \(key.subtitle)"
        }
        return listing?.emptyReason
    }
}

extension SigningKeys {
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
