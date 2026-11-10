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
    /// The name, version and path of a copy Roga can't use, in its menu:
    /// half as strong as a note, so that the row reads as one that can't be
    /// chosen, and its reason is the easiest thing in it to read.
    static let unavailable = SettingsColors.note.opacity(0.5)
    /// The lines between a card's rows, a shade darker than the card.
    static let rule = DialogColors.appearanceColor(light: 0xE1E1DE, dark: 0x464644)
    /// The small word over a screen's heading, in the brand's orange, dark
    /// enough to read at that size.
    static let eyebrow = DialogColors.appearanceColor(light: 0xB83E02, dark: 0xF0813F)
}

/// A program Roga runs, as one row: an icon, its name and version, a check
/// for having been found, its path, and at the right a button that names
/// where this copy is from and opens a menu of every copy Roga found. Git,
/// Claude Code and Codex each get the same row, in setup and in Settings.
struct ProgramRow: View {
    let icon: Icon
    let content: ProgramRowContent
    /// The menu the button opens, for a row whose button is one.
    var menu: ProgramMenu?
    /// What Choose… does, for a program Roga didn't find.
    var choose: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            icon.image
                .font(.system(size: 17))
                .foregroundStyle(SetupColors.note)
                .frame(width: 38, height: 38)
                .background(SetupColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
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
            if let menu {
                ProgramSelect(title: title, menu: menu)
            }
        case .choose:
            Button("Choose…", action: choose)
                .buttonStyle(ProgramSelectStyle(isOpen: false, hasChevrons: false))
                .accessibilityLabel("Choose \(content.name)…")
        }
    }
}

/// A gray card of rows with a line between each, such as the programs Roga
/// will run. `clips` rounds what reaches the card's edges, for a card that
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

// MARK: The menu

/// The menu a program's row opens: every copy Roga found, then Choose
/// another…, and for an agent the way to not use it.
struct ProgramMenu {
    /// Not using the program at all, as in Don't use Codex.
    struct Skip {
        var title: String
        /// Whether it's what's chosen now.
        var isOn: Bool
        var action: () -> Void
    }

    /// Which row's menu it is, so that only one is open.
    var id: String
    /// What VoiceOver calls it, as in "Every Git Roga found".
    var label: String
    var choices: [ProgramChoice]
    /// The copy in use, which gets the check.
    var checked: String?
    var choose: (ProgramChoice) -> Void
    var chooseAnother: () -> Void
    var skip: Skip?
}

/// Which program's menu is open, for everything under one `programMenus()`.
@MainActor @Observable
final class ProgramMenus {
    var open: String?

    func toggle(_ id: String) {
        open = open == id ? nil : id
    }
}

/// Where each row's button is and what its menu holds, which the rows report
/// up to whatever draws the open one over everything else.
nonisolated struct ProgramMenuPlaces: PreferenceKey {
    struct Place {
        var bounds: Anchor<CGRect>
        var menu: ProgramMenu
    }

    static var defaultValue: [String: Place] { [:] }

    static func reduce(value: inout [String: Place], nextValue: () -> [String: Place]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Draws the open menu of any `ProgramRow` inside, over everything else
    /// in this view, under the button that opened it, and closes it on a
    /// click anywhere else. A row's menu is drawn up here because a row sits
    /// inside a card and a column, and what comes after those would draw over
    /// a menu the row drew itself.
    ///
    /// - Parameter open: The row whose menu is open at first, for drawing
    ///   one in a test.
    func programMenus(open: String? = nil) -> some View {
        modifier(ProgramMenuHost(open: open))
    }
}

private struct ProgramMenuHost: ViewModifier {
    @State private var menus: ProgramMenus

    init(open: String?) {
        let menus = ProgramMenus()
        menus.open = open
        _menus = State(initialValue: menus)
    }

    /// How tall the open menu is, once it's laid out, to keep it in view.
    @State private var menuHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(menus)
            .overlayPreferenceValue(ProgramMenuPlaces.self) { places in
                GeometryReader { proxy in
                    if let id = menus.open, let place = places[id] {
                        let origin = ProgramMenuPlacement.origin(
                            button: proxy[place.bounds],
                            menu: CGSize(width: ProgramMenuView.width, height: menuHeight),
                            in: proxy.size
                        )
                        ZStack(alignment: .topLeading) {
                            // Everything outside the menu closes it.
                            Button {
                                menus.open = nil
                            } label: {
                                Color.clear
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(ProgramMenuRowStyle())
                            .accessibilityLabel("Close the Menu")
                            ProgramMenuView(menu: place.menu) { menus.open = nil }
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeight = $0 }
                                .offset(x: origin.x, y: origin.y)
                        }
                    }
                }
            }
            .onChange(of: menus.open) { menuHeight = 0 }
    }
}

/// Where an open menu goes, over whatever `programMenus()` is on.
nonisolated enum ProgramMenuPlacement {
    /// The gap between a button and its menu, and between a menu and the
    /// edge of what it's drawn over.
    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    /// Where the menu's top left goes: under the button, with their right
    /// edges in line, or over the button when there's no room under it and
    /// there is over it. It never runs off the left edge.
    static func origin(button: CGRect, menu: CGSize, in container: CGSize) -> CGPoint {
        let x = max(margin, min(button.maxX - menu.width, container.width - menu.width - margin))
        let under = button.maxY + gap
        let over = button.minY - gap - menu.height
        let fitsUnder = under + menu.height <= container.height - margin
        return CGPoint(x: x, y: fitsUnder || over < margin ? under : over)
    }
}

/// The button at the right of a program's row, which says where the copy in
/// use is from and opens the menu.
struct ProgramSelect: View {
    let title: String
    let menu: ProgramMenu
    @Environment(ProgramMenus.self) private var menus: ProgramMenus?

    var body: some View {
        let isOpen = menus?.open == menu.id
        Button(title) {
            menus?.toggle(menu.id)
        }
        .buttonStyle(ProgramSelectStyle(isOpen: isOpen, hasChevrons: true))
        .anchorPreference(key: ProgramMenuPlaces.self, value: .bounds) {
            [menu.id: ProgramMenuPlaces.Place(bounds: $0, menu: menu)]
        }
        .accessibilityLabel(menu.label)
        .accessibilityValue(title)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

/// The canvas's select, with a line around it and chevrons at its end. While
/// its menu is open, the line is ink with a soft ring outside it.
private struct ProgramSelectStyle: ButtonStyle {
    let isOpen: Bool
    let hasChevrons: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 8) {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if hasChevrons {
                Icon.chevronsUpDown.image
                    .font(.system(size: 12.5))
                    .foregroundStyle(SetupColors.note)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, hasChevrons ? 7 : 12)
        .frame(height: 30)
        .background(SetupColors.surface, in: shape)
        .overlay {
            shape.strokeBorder(isOpen ? SetupColors.ink : SetupColors.line, lineWidth: 1)
        }
        .background {
            if isOpen {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SetupColors.hover)
                    .padding(-3)
            }
        }
        .opacity(configuration.isPressed ? 0.75 : 1)
        .contentShape(shape)
        .fixedSize()
    }
}

/// The open menu: a copy to a row, with where it's from, a tag, its version,
/// its path and why Roga would or wouldn't run it.
///
/// It takes the keyboard while it's open: the arrows move through what can
/// be chosen, Return chooses, and Escape closes it.
private struct ProgramMenuView: View {
    static let width: CGFloat = 404

    let menu: ProgramMenu
    let close: () -> Void
    /// The item the arrows are on, or nil before a key is pressed.
    @State private var highlighted: Int?
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// What can be chosen, in order, which is what the arrows move through.
    private enum Item: Equatable {
        case choice(String)
        case another
        case skip
    }

    private var items: [Item] {
        menu.choices.filter(\.canChoose).map { .choice($0.executable) } + [.another] + (menu.skip == nil ? [] : [.skip])
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            ForEach(menu.choices) { choice in
                ProgramChoiceRow(
                    choice: choice,
                    isChecked: choice.executable == menu.checked && menu.skip?.isOn != true,
                    isHighlighted: isHighlighted(.choice(choice.executable))
                ) {
                    pick(.choice(choice.executable))
                }
            }
            Rectangle()
                .fill(SetupColors.hairline)
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            ProgramCommandRow(title: "Choose another…", isChecked: false, isHighlighted: isHighlighted(.another)) {
                pick(.another)
            }
            if let skip = menu.skip {
                ProgramCommandRow(title: skip.title, isChecked: skip.isOn, isHighlighted: isHighlighted(.skip)) {
                    pick(.skip)
                }
            }
        }
        .padding(6)
        .frame(width: Self.width)
        .background(SetupColors.surface, in: shape)
        .overlay {
            shape.strokeBorder(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.2), radius: 22, y: 16)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(.downArrow) {
            move(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            move(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            guard let highlighted, items.indices.contains(highlighted) else { return .ignored }
            pick(items[highlighted])
            return .handled
        }
        // Once it's on screen, since a view can't take the keyboard in the
        // update that puts it there.
        .task { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(menu.label)
    }

    private func isHighlighted(_ item: Item) -> Bool {
        highlighted.map { items.indices.contains($0) && items[$0] == item } ?? false
    }

    private func move(by step: Int) {
        let count = items.count
        guard count > 0 else { return }
        highlighted = highlighted.map { ($0 + step + count) % count } ?? (step > 0 ? 0 : count - 1)
    }

    private func pick(_ item: Item) {
        close()
        switch item {
        case .choice(let executable):
            if let choice = menu.choices.first(where: { $0.executable == executable }) { menu.choose(choice) }
        case .another:
            menu.chooseAnother()
        case .skip:
            menu.skip?.action()
        }
    }
}

/// A copy of a program in the menu.
private struct ProgramChoiceRow: View {
    let choice: ProgramChoice
    let isChecked: Bool
    let isHighlighted: Bool
    let action: () -> Void
    @State private var isHovering = false

    /// The color of the version and the path. A copy Roga can't use fades
    /// them and its name, and leaves its tag and its reason as they are.
    private var detail: Color {
        choice.canChoose ? SetupColors.note : SetupColors.unavailable
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                ChoiceCheck(isChecked: isChecked)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(choice.source)
                            .fontWeight(.medium)
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
                        .fixedSize(horizontal: false, vertical: true)
                    Text(choice.why)
                        .font(.system(size: 12))
                        .foregroundStyle(SetupColors.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(choice.canChoose ? Color.primary : SetupColors.unavailable)
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 10))
            .background(
                choice.canChoose && (isHovering || isHighlighted) ? SetupColors.hover : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(ProgramMenuRowStyle())
        .disabled(!choice.canChoose)
        .onHover { isHovering = $0 }
        .accessibilityLabel(choice.spoken)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}

/// A command in the menu, under the copies: Choose another…, or not using
/// the program. They're in sentence case, as menus in the window are
/// (decision 66).
private struct ProgramCommandRow: View {
    let title: String
    let isChecked: Bool
    let isHighlighted: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ChoiceCheck(isChecked: isChecked)
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 10))
            .background(isHovering || isHighlighted ? SetupColors.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(ProgramMenuRowStyle())
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}

/// A row of the menu as a button. A copy Roga can't use fades its own name,
/// version and path and keeps its reason readable, so the row isn't dimmed
/// as a whole the way the system dims what's turned off.
private struct ProgramMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
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
        panel.message = "Choose the \(name) program for Roga to run."
        if let current {
            panel.directoryURL = URL(filePath: (current as NSString).deletingLastPathComponent, directoryHint: .isDirectory)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }
}
