import AppKit
import IconUI
import SwiftUI

/// The colors of setup, from the design canvas's First run boards, which use
/// the dialogs' and Settings' so that the three look like one family.
enum SetupColors {
    static let surface = SettingsColors.surface
    static let card = SettingsColors.card
    static let note = SettingsColors.note
    static let ink = SettingsColors.ink
    static let line = SettingsColors.line
    static let hairline = SettingsColors.hairline
    static let hover = SettingsColors.hover
    /// The name, version and path of a copy Roga can't use, on its card:
    /// half as strong as a note, so that the row reads as one that can't be
    /// chosen, and its reason is the easiest thing in it to read.
    static let unavailable = SettingsColors.note.opacity(0.5)
    /// The lines between a card's rows, a shade darker than the card.
    static let rule = DialogColors.appearanceColor(light: 0xE1E1DE, dark: 0x464644)
    /// The small word over a screen's heading, in the brand's orange, dark
    /// enough to read at that size.
    static let eyebrow = DialogColors.appearanceColor(light: 0xB83E02, dark: 0xF0813F)
}

/// A program Roga runs, as one row: its name and version, a check for having
/// been found, its path, and at the right a button that names where this
/// copy is from and opens a popover of every copy Roga found. Git, Claude
/// Code and Codex each get the same row, in setup and in Settings. There's no
/// icon before the name, which would say nothing the name doesn't, as on the
/// Agents page.
struct ProgramRow: View {
    let content: ProgramRowContent
    /// What the button's popover offers, for a row whose button opens one.
    var picker: ProgramPicker?
    /// What Choose… does, for a program Roga didn't find.
    var choose: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                title
                line
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.spoken)
            select
        }
        .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 14))
        .frame(minHeight: 68)
    }

    private var title: some View {
        HStack(spacing: 8) {
            Text(content.name)
                .font(.system(size: 14.5, weight: content.isDimmed ? .medium : .semibold))
                .foregroundStyle(content.isDimmed ? SetupColors.note : .primary)
            if let version = content.version {
                Text(verbatim: version)
                    .font(.system(size: 13.5))
                    .monospacedDigit()
                    .foregroundStyle(SetupColors.note)
            }
            switch content.status {
            case .none:
                EmptyView()
            case .detected:
                HStack(spacing: 3) {
                    Icon.check.image
                        .font(.system(size: 10.5, weight: .bold))
                    Text("Detected")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AgentColors.ok)
                .padding(.leading, 2)
            case .warning(let words):
                Text(words)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AgentColors.warn)
                    .padding(.leading, 2)
            }
        }
        .lineLimit(1)
        .frame(height: 20)
    }

    @ViewBuilder private var line: some View {
        switch content.tone {
        case .path:
            Text(verbatim: content.line)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(SetupColors.note)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(content.line)
        case .plain, .warn:
            Text(content.line)
                .font(.system(size: 12))
                .foregroundStyle(content.tone == .warn ? AgentColors.warn : SetupColors.note)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var select: some View {
        switch content.select {
        case .none:
            EmptyView()
        case .menu(let title):
            if let picker {
                ProgramSelect(title: title, picker: picker, isOnCard: true)
            }
        case .choose:
            Button("Choose…", action: choose)
                .buttonStyle(ProgramSelectStyle(isOpen: false, hasChevrons: false, isOnCard: true))
                .accessibilityLabel("Choose \(content.name)…")
        }
    }
}

/// A gray card of rows with a line between each, for what Roga found on the
/// Mac: the programs it will run, in setup and in Settings, and the agents and
/// their plugins on the Agents page. The settings about them sit on the page
/// with no card. `clips` rounds what reaches the card's edges, for a card that
/// ends in a command block.
struct SetupCard<Content: View>: View {
    var clips = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let rows = VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle()
                            .fill(SetupColors.rule)
                            .frame(height: 1)
                    }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(SetupColors.card, in: shape)
        if clips {
            rows.clipShape(shape)
        } else {
            rows
        }
    }
}

// MARK: The popover

/// What a program's row lets someone choose: every copy Roga found, then
/// Choose Another…. There's no way to leave one agent out, since agents are on
/// or off together (decision 89).
struct ProgramPicker {
    /// Which row's it is, as "git" or "agent-claude".
    var id: String
    /// The popover's heading, which VoiceOver also calls the row's button, as
    /// in "Git installation".
    var title: String
    var choices: [ProgramChoice]
    /// The copy in use, whose card is picked.
    var picked: String?
    var choose: (ProgramChoice) -> Void
    var chooseAnother: () -> Void
}

extension EnvironmentValues {
    /// The row whose popover is open when it appears, as "git", for drawing a
    /// screen with a popover open in a preview.
    @Entry var openProgramPicker: String? = nil
}

/// The button at the right of a program's row, which says where the copy in
/// use is from and opens the popover of every copy, as the chevron beside
/// Generate opens the agents' (decision 101).
struct ProgramSelect: View {
    let title: String
    let picker: ProgramPicker
    /// Whether it's on a program's card rather than a page's row.
    var isOnCard = false
    @State private var isOpen = false
    @Environment(\.openProgramPicker) private var openPicker

    var body: some View {
        Button(title) {
            isOpen.toggle()
        }
        .buttonStyle(ProgramSelectStyle(isOpen: isOpen, hasChevrons: true, isOnCard: isOnCard))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ProgramPopover(picker: picker) { isOpen = false }
        }
        .onAppear {
            if openPicker == picker.id { isOpen = true }
        }
        .accessibilityLabel(picker.title)
        .accessibilityValue(title)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

/// Drawn as Settings' dropdowns are, a step stronger on a program's card:
/// a gray box with the chevron at its end, lighter under the pointer, and the
/// accent ring while its popover is open. Choose… is the same box without
/// the chevron.
private struct ProgramSelectStyle: ButtonStyle {
    let isOpen: Bool
    let hasChevrons: Bool
    var isOnCard = false

    func makeBody(configuration: Configuration) -> some View {
        ProgramSelectBox(configuration: configuration, isOpen: isOpen, hasChevrons: hasChevrons, isOnCard: isOnCard)
    }
}

private struct ProgramSelectBox: View {
    let configuration: ButtonStyleConfiguration
    let isOpen: Bool
    let hasChevrons: Bool
    let isOnCard: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            configuration.label
                .font(.system(size: 13))
                .lineLimit(1)
            if hasChevrons {
                SettingsChevron()
            }
        }
        .padding(.leading, hasChevrons ? 9 : 12)
        .padding(.trailing, hasChevrons ? 8 : 12)
        .frame(height: SettingsBoxMetrics.height)
        .settingsBox(isHovering: isHovering, isFocused: isOpen, isOnCard: isOnCard)
        .opacity(configuration.isPressed ? 0.75 : 1)
        .contentShape(RoundedRectangle(cornerRadius: SettingsBoxMetrics.cornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
        .fixedSize()
    }
}

/// Every copy of a program Roga found, laid out as the agents' popover is
/// (decision 91): a heading, a card for each copy with a radio, where it's
/// from, a tag, its version, its path and why Roga would or wouldn't run it,
/// and under the cards a note that the pick is saved and Choose Another…. The
/// copy in use has the ink edge. A copy Roga can't run is gray, and its card
/// can't be picked. A pick is used at once, so the popover stays open to show
/// it, and closes as any popover does.
struct ProgramPopover: View {
    let picker: ProgramPicker
    let close: () -> Void

    /// As wide as the agents' popover.
    static var width: CGFloat { AgentPopover.width }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(picker.title)
                .font(.system(size: 13, weight: .semibold))
                .padding(EdgeInsets(top: 13, leading: 16, bottom: 8, trailing: 16))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 6) {
                ForEach(picker.choices) { choice in
                    ProgramCard(choice: choice, isPicked: choice.executable == picker.picked) {
                        picker.choose(choice)
                    }
                }
            }
            .padding(.horizontal, 10)
            HStack(spacing: 12) {
                Text("Selection saved automatically.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DialogColors.note)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose Another…") {
                    // The panel is modal, and can't open over a popover.
                    close()
                    picker.chooseAnother()
                }
                .buttonStyle(.settings(small: true))
                .fixedSize()
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 12))
        }
        .frame(width: Self.width)
        .font(.system(size: 13))
        // A plain surface over the system's material, like a dialog's.
        .background {
            DialogColors.surface
                .padding(-24)
        }
        .background {
            // Escape closes it, as it does a menu.
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(picker.title)
    }
}

/// One copy in the popover, as a card like an agent's: a radio, where it's
/// from with its tag and version, its path, and why Roga would or wouldn't
/// run it. The copy in use has an ink edge twice as thick as the others'
/// line. One Roga can't run fades its name, version and path, keeps its tag
/// and its reason readable, and can't be picked.
private struct ProgramCard: View {
    let choice: ProgramChoice
    let isPicked: Bool
    let pick: () -> Void
    @State private var isHovering = false

    private var detail: Color {
        choice.canChoose ? SetupColors.note : SetupColors.unavailable
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                AgentRadio(isOn: isPicked)
                    .opacity(choice.canChoose ? 1 : 0.45)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(choice.source)
                            .foregroundStyle(choice.canChoose ? Color.primary : SetupColors.unavailable)
                        if let tag = choice.tag {
                            ProgramTag(tag: tag)
                        }
                        Spacer(minLength: 8)
                        if let version = choice.version {
                            Text(verbatim: version)
                                .monospacedDigit()
                                .foregroundStyle(detail)
                        }
                    }
                    .lineLimit(1)
                    Text(verbatim: choice.path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(detail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(choice.why)
                        .font(.system(size: 12))
                        .foregroundStyle(DialogColors.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // As on the agents' cards, the pointer over a card that can be
                // picked shades it.
                if isHovering, !isPicked, choice.canChoose {
                    shape.fill(SettingsColors.hover)
                }
            }
            .overlay {
                shape.strokeBorder(isPicked ? DialogColors.ink : SettingsColors.line, lineWidth: isPicked ? 2 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(AgentCardStyle())
        .disabled(!choice.canChoose)
        .onHover { isHovering = $0 }
        .accessibilityLabel(choice.spoken)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// Recommended in a thin gray pill, or why Roga can't use a copy in amber.
private struct ProgramTag: View {
    let tag: ProgramChoice.Tag

    var body: some View {
        if tag.isWarning {
            Text(tag.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentColors.warn)
        } else {
            Text(tag.title)
                .font(.system(size: 11))
                .foregroundStyle(SetupColors.note)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(height: 19)
                .overlay {
                    Capsule().strokeBorder(SetupColors.line, lineWidth: 1)
                }
        }
    }
}

// MARK: Choosing a program

/// The open panel that asks for a program, for a copy that isn't anywhere
/// Roga looks.
enum ProgramPanel {
    /// - Parameters:
    ///   - name: The program's file name, as in `git`.
    ///   - current: The copy in use, whose folder the panel opens at.
    /// - Returns: The chosen program's path, or nil when the panel was
    ///   cancelled.
    static func choose(_ name: String, startingAt current: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // The Codex inside the ChatGPT app is inside its bundle, and Claude
        // Code's is in a hidden folder.
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        panel.message = "Choose the \(name) program to use."
        if let current {
            panel.directoryURL = URL(filePath: (current as NSString).deletingLastPathComponent, directoryHint: .isDirectory)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }
}
