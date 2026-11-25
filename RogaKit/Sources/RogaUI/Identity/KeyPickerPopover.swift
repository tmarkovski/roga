import GitCore
import RepositoryEngine
import SwiftUI

/// The keys this Mac can sign with in a format, as cards with a radio, laid
/// out as the popover for a program's copies is (decision 101): a heading, a
/// card for each key with its name, its type, what tells it apart and its
/// fingerprint, and under the cards a note on when the pick is saved
/// (decision 106). New SSH Key… and New OpenPGP Key… are only under the
/// field (decision 108). The key the field names has the ink edge. Picking
/// one fills the field and closes it.
struct KeyPickerPopover: View {
    let format: CommitIdentity.SigningFormat
    let keys: [SigningKey]
    /// The listed key the field names, if any.
    let picked: SigningKey?
    /// Whether to offer leaving `user.signingkey` unset, for
    /// `gpg.ssh.defaultKeyCommand` to pick a key.
    let offersDefault: Bool
    /// Whether the field is empty, which is the default's pick.
    let isEmpty: Bool
    /// Whether a pick is saved at once, as in Settings.
    let savesAtOnce: Bool
    let pick: (String) -> Void
    let close: () -> Void

    /// As wide as the agents' popover and the program popover.
    static var width: CGFloat { AgentPopover.width }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(format.title) keys on this Mac")
                .font(.system(size: 13, weight: .semibold))
                .padding(EdgeInsets(top: 13, leading: 16, bottom: 8, trailing: 16))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 6) {
                if offersDefault {
                    KeyCard(
                        title: "Whatever gpg.ssh.defaultKeyCommand picks",
                        kind: nil,
                        detail: "Leaves user.signingkey unset",
                        fingerprint: nil,
                        isPicked: isEmpty
                    ) { choose("") }
                }
                ForEach(keys) { key in
                    KeyCard(
                        title: key.title,
                        kind: key.details.first,
                        // Without an OpenPGP key's ID, which ends the fingerprint under it.
                        detail: key.details.dropFirst().filter { !key.fingerprint.hasSuffix($0) }.joined(separator: " · "),
                        fingerprint: key.fingerprint,
                        isPicked: key.id == picked?.id
                    ) { choose(key.value) }
                }
            }
            .padding(.horizontal, 10)
            Text(savesAtOnce ? "A key you pick is saved at once." : "Save writes the key you pick.")
                .font(.system(size: 12.5))
                .foregroundStyle(DialogColors.note)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
        }
        .frame(width: Self.width)
        .font(.system(size: 13))
        .background {
            DialogColors.surface
                .padding(-24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(format.title) keys on this Mac")
    }

    private func choose(_ value: String) {
        pick(value)
        close()
    }
}

/// One key as a card: a radio, its name with its type at the end, what else
/// tells it apart, and its fingerprint. The key the field names has an ink
/// edge twice as thick as the others' line.
private struct KeyCard: View {
    let title: String
    let kind: String?
    let detail: String
    let fingerprint: String?
    let isPicked: Bool
    let pick: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                AgentRadio(isOn: isPicked)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(verbatim: title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let kind {
                            Text(verbatim: kind)
                                .font(.system(size: 11.5))
                                .foregroundStyle(DialogColors.note)
                        }
                    }
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.system(size: 12))
                            .foregroundStyle(DialogColors.note)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let fingerprint {
                        Text(verbatim: fingerprint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DialogColors.note)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHovering, !isPicked {
                    shape.fill(SettingsColors.hover)
                }
            }
            .overlay {
                shape.strokeBorder(isPicked ? DialogColors.ink : SettingsColors.line, lineWidth: isPicked ? 2 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(AgentCardStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel([title, kind, detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}
