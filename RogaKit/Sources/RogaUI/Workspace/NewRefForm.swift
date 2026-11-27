import SwiftUI

/// What the popovers for a new branch, a new worktree and a new tag share.
/// They're drawn the way the identity popover is, like a dialog (decision
/// 29): a title with what the new ref starts from in gray under it, a field
/// for its name and any switches, then Cancel and the button that makes
/// it, and the exact command in the dark block along the bottom, as it's
/// typed.
struct NewRefForm<Options: View>: View {
    let title: String
    /// What it starts from, as in `From main`.
    let subtitle: String?
    var subtitleLineLimit = 1
    @Binding var name: String
    var placeholder = "Name"
    /// What the button that makes it says, as in Create Branch.
    let action: String
    /// What it runs, which the block shows once the name has something in it.
    let commands: [[String]]
    /// What the block says while the name is empty.
    let emptyNote: String
    /// What git said when it refused.
    let refusal: String?
    let isCreating: Bool
    let create: () -> Void
    let close: () -> Void
    @ViewBuilder var options: Options

    @FocusState private var isNameFocused: Bool

    static var width: CGFloat { 340 }
    private static var inset: CGFloat { 16 }

    private var hasName: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(DialogColors.note)
                        .lineLimit(subtitleLineLimit)
                        .truncationMode(.middle)
                }
            }
            .padding(EdgeInsets(top: 13, leading: Self.inset, bottom: 12, trailing: Self.inset))
            VStack(alignment: .leading, spacing: 12) {
                SettingsTextField(text: $name, placeholder: placeholder, width: Self.width - 2 * Self.inset)
                    .focused($isNameFocused)
                    .accessibilityLabel(placeholder)
                    .onSubmit(create)
                options
                if let refusal {
                    Text(refusal)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Self.inset)
            HStack(spacing: 8) {
                DialogActionButton(button: .cancel(close))
                DialogActionButton(button: DialogButton(title: action, kind: .primary, isEnabled: hasName && !isCreating, action: create))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(EdgeInsets(top: 16, leading: Self.inset, bottom: 14, trailing: Self.inset))
            CommandBlock(lines: hasName ? commands.map { .command($0) } : [.comment(emptyNote)], isCompact: true)
        }
        .frame(width: Self.width)
        .font(.system(size: 13))
        .background(DialogColors.surface)
        .onAppear { isNameFocused = true }
    }
}

/// A switch in one of those popovers, such as In a new worktree, with what
/// it does before it, as Sign commits is in the identity popover.
struct NewRefSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.settings)
                .labelsHidden()
        }
    }
}
