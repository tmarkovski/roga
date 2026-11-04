import AppKit
import IconUI
import SwiftUI

/// The colors of a dialog, which are its own so that it reads the same over any
/// window: a plain surface, gray cards and a dark terminal block.
enum DialogColors {
    static let surface = Palette.gray(light: 1.0, dark: 0.165)
    static let card = Palette.gray(light: 0.949, dark: 0.208)
    static let secondaryButton = Palette.gray(light: 0.937, dark: 0.231)
    /// Darker than `Color.secondary`, which is too faint for small words on a card.
    static let note = Palette.gray(light: 0.42, dark: 0.663)
    static let ink = Palette.ink
    static let onInk = Palette.onInk
    static let danger = Palette.red
    static let onDanger = appearanceColor(light: 0xFFFFFF, dark: 0x272822)
    /// Monokai's background, which nearly matches the surface in dark mode, so that
    /// goes darker.
    static let terminal = appearanceColor(light: 0x272822, dark: 0x1A1B17)

    private static func appearanceColor(light: Int, dark: Int) -> Color {
        func color(_ value: Int) -> NSColor {
            NSColor(
                srgbRed: CGFloat(value >> 16 & 0xFF) / 255,
                green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
        let (light, dark) = (color(light), color(dark))
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

/// What every dialog looks like: a title and an ×, what will happen, any cards, the
/// buttons, and the exact command along the bottom edge (decision 29). `extra` is
/// for what only one dialog needs, and goes after the cards.
///
/// Show one with `.dialog(_:)`, or with `.sheet(item:)` when it has an `extra`.
struct DialogSheet<Extra: View>: View {
    let content: DialogContent
    @ViewBuilder var extra: Extra

    /// As wide as the longest commands Roga runs usually are, on one line.
    static var width: CGFloat { 480 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let message = content.message {
                    words(message)
                }
                ForEach(Array(content.cards.enumerated()), id: \.offset) { _, rows in
                    DialogCard(rows: rows)
                }
                if !content.switches.isEmpty {
                    DialogSwitchCard(switches: content.switches)
                }
                ForEach(Array(content.cardsAfterSwitches.enumerated()), id: \.offset) { _, rows in
                    DialogCard(rows: rows)
                }
                extra
                if let note = content.note {
                    words(note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DialogColors.note)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(content.buttons.enumerated()), id: \.offset) { _, button in
                    DialogActionButton(button: button)
                }
            }
            .padding(EdgeInsets(top: 0, leading: 18, bottom: content.terminal.isEmpty ? 16 : 14, trailing: 18))
            if !content.terminal.isEmpty {
                CommandBlock(lines: content.terminal)
            }
        }
        .frame(width: Self.width)
        .background(DialogColors.surface)
        .font(.system(size: 13))
        .presentationSizing(.fitted)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(content.title)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button(action: content.dismiss) {
                Icon.x.image
                    .font(.system(size: 13))
            }
            .buttonStyle(.icon(size: 24))
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
            .padding(EdgeInsets(top: -2, leading: 0, bottom: 0, trailing: -4))
        }
    }

    private func words(_ text: DialogText) -> some View {
        Text(text.attributed)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension DialogSheet where Extra == EmptyView {
    init(content: DialogContent) {
        self.init(content: content) { EmptyView() }
    }
}

/// A gray card of rows, such as the commits something would lose.
struct DialogCard: View {
    let rows: [DialogRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                self.row(row)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DialogColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private func row(_ row: DialogRow) -> some View {
        switch row {
        case .commit(let hash, let subject):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: hash)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DialogColors.note)
                Text(verbatim: subject)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .fact(let name, let what):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(name)
                    .fontWeight(.medium)
                    .frame(width: 136, alignment: .leading)
                Text(what)
                    .foregroundStyle(DialogColors.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .name(let name):
            Text(verbatim: name)
                .font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        case .more(let text):
            Text(text)
                .foregroundStyle(DialogColors.note)
        case .heading(let text, let isLost):
            Text(text)
                .font(.system(size: 12.5, weight: isLost ? .medium : .regular))
                .foregroundStyle(isLost ? DialogColors.danger : DialogColors.note)
        }
    }
}

/// A gray card of what's up to the user, with a line between each switch.
struct DialogSwitchCard: View {
    let switches: [DialogSwitch]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(switches.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                DialogSwitchRow(item: item)
            }
        }
        .background(DialogColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DialogSwitchRow: View {
    let item: DialogSwitch

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.attributed)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.detail.attributed)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DialogColors.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            toggle
        }
        .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
    }

    @ViewBuilder private var toggle: some View {
        let toggle = Toggle(item.title.plain, isOn: Binding { item.isOn } set: { _ in item.flip() })
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(DialogColors.ink)
            .fixedSize()
        if let key = item.key {
            toggle
                .keyboardShortcut(KeyEquivalent(key), modifiers: [])
                .help("\(item.help ?? item.title.plain) (\(String(key).uppercased()))")
        } else {
            toggle
        }
    }
}

private struct DialogActionButton: View {
    let button: DialogButton

    var body: some View {
        switch button.kind {
        case .secondary:
            base
        case .primary:
            base.keyboardShortcut(.defaultAction)
        case .destructive:
            base.keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var base: some View {
        Button(button.title, action: button.action)
            .buttonStyle(DialogButtonStyle(kind: button.kind))
            .disabled(!button.isEnabled)
    }
}

/// The soft rectangles along the bottom of a dialog.
private struct DialogButtonStyle: ButtonStyle {
    let kind: DialogButton.Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .secondary: .primary
        case .primary: DialogColors.onInk
        case .destructive: DialogColors.onDanger
        }
    }

    private var background: Color {
        switch kind {
        case .secondary: DialogColors.secondaryButton
        case .primary: DialogColors.ink
        case .destructive: DialogColors.danger
        }
    }
}

extension View {
    /// Shows a dialog for as long as there's one to show, and keeps it up to date
    /// while it shows, for a dialog with switches.
    func dialog(_ content: @escaping () -> DialogContent?) -> some View {
        sheet(item: Binding {
            content()
        } set: { newValue in
            if newValue == nil { content()?.dismiss() }
        }) { shown in
            LiveDialogSheet(content: content, shown: shown)
        }
    }
}

/// Reads its dialog in its own body, because a sheet's item doesn't update what the
/// sheet shows while its `id` stays the same.
private struct LiveDialogSheet: View {
    let content: () -> DialogContent?
    /// The dialog as it was shown, for while the sheet closes and it's gone.
    let shown: DialogContent

    var body: some View {
        DialogSheet(content: content() ?? shown)
    }
}
