import AppKit
import IconUI
import SwiftUI

/// The colors of the Settings sheet, from the design canvas's Settings boards,
/// which use the dialogs' (decision 29) so that the two look like one family.
enum SettingsColors {
    static let surface = DialogColors.surface
    static let card = DialogColors.card
    /// The gray of help under a setting, and of icons that aren't selected.
    static let note = DialogColors.note
    static let ink = DialogColors.ink
    /// Behind a button that isn't the main one, as in a dialog.
    static let secondaryButton = DialogColors.secondaryButton
    /// What failed, in the agent's own words.
    static var danger: Color { DialogColors.danger }
    /// The border of the search field, and a switch that's off.
    static let line = Palette.gray(light: 0.839, dark: 0.29)
    /// The lines between rows, and around the sidebar and the header.
    static let hairline = Palette.gray(light: 0.918, dark: 0.224)
    /// Behind the sidebar, a shade off the page beside it.
    static let sidebar = Palette.gray(light: 0.965, dark: 0.141)
    /// Under the page that's showing.
    static let selectedPage = Palette.gray(light: 0.898, dark: 0.227)
    /// Under a page while the pointer is over it, lighter than the selected one.
    static let hover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07)
            : NSColor(white: 0, alpha: 0.05)
    })
}

extension VerticalAlignment {
    private enum SettingsFirstLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    /// The middle of a row's first line, which is its name, for the controls
    /// at the row's top right, in every row of Settings. They stay beside the
    /// name however many lines go under it, as a row's commands do elsewhere
    /// in Roga.
    static let settingsFirstLine = VerticalAlignment(SettingsFirstLine.self)
}

/// A group of settings under a heading, with a thin line between its rows and
/// no card around them.
struct SettingsSection<Aside: View, Content: View>: View {
    let title: String
    /// Gray words under the heading that say what the whole group is about.
    var description: AttributedString?
    @ViewBuilder var aside: Aside
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                aside
            }
            .frame(minHeight: 26, alignment: .leading)
            .padding(.bottom, 4)
            if let description {
                Text(description)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(SettingsColors.note)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle()
                            .fill(SettingsColors.hairline)
                            .frame(height: 1)
                    }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsSection where Aside == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, aside: { EmptyView() }, content: content)
    }
}

/// One setting: its name and gray help on the left, and its control on the
/// right, on the name's line, so that it stays beside the name however long
/// the help is or however it changes. Help that's more than words, such as a program's path in the code
/// font, goes in `detail`, and `help` then says all of it in words. VoiceOver
/// reads the name and the detail as one element, with `help` as its value,
/// so it hears the whole sentence once rather than the detail's pieces.
///
/// VoiceOver calls the control by the setting's name, unless `namesControl`
/// is off, for buttons that say what they do, such as Choose….
struct SettingsRow<Detail: View, Control: View>: View {
    let title: String
    var help: String?
    let detail: Detail?
    var namesControl = true
    @ViewBuilder var control: Control

    init(title: String, help: String?, namesControl: Bool = true, @ViewBuilder detail: () -> Detail, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.namesControl = namesControl
        self.detail = detail()
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .settingsFirstLine, spacing: 16) {
            if let spokenDetail {
                words
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityValue(spokenDetail)
            } else {
                words
            }
            if namesControl {
                control
                    .fixedSize()
                    .accessibilityLabel(title)
                    .accessibilityHint(help ?? "")
                    .alignmentGuide(.settingsFirstLine) { $0[VerticalAlignment.center] }
            } else {
                control
                    .fixedSize()
                    .alignmentGuide(.settingsFirstLine) { $0[VerticalAlignment.center] }
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: hasHelp ? 56 : 46)
    }

    private var hasHelp: Bool {
        detail != nil || help?.isEmpty == false
    }

    /// What VoiceOver reads after the name when a detail shows: `help`,
    /// which says in words what the detail draws. Without a detail, the help
    /// shows as it is and is read as it shows.
    var spokenDetail: String? {
        guard detail != nil, let help, !help.isEmpty else { return nil }
        return help
    }

    /// The name, and the help or the detail under it.
    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .alignmentGuide(.settingsFirstLine) { $0[VerticalAlignment.center] }
            if let detail {
                detail
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(SettingsColors.note)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let help, !help.isEmpty {
                Text(help)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(SettingsColors.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsRow where Detail == EmptyView {
    init(title: String, help: String?, namesControl: Bool = true, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.namesControl = namesControl
        self.detail = nil
        self.control = control()
    }
}

/// Something that isn't a setting, such as the house's animations, in the
/// list of rows.
struct SettingsBlock<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.vertical, 12)
    }
}

/// A switch in ink, the color of what's on in a dialog, rather than the accent
/// color.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? SettingsColors.ink : SettingsColors.line)
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? SettingsColors.surface : .white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        .padding(2)
                }
                .animation(.snappy(duration: 0.15), value: configuration.isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension ToggleStyle where Self == SettingsSwitchStyle {
    static var settings: SettingsSwitchStyle { SettingsSwitchStyle() }
}

/// Buttons side by side on a gray strip, each as wide as the widest, with the
/// one that's chosen raised in white. An icon before a button's title is gray
/// until it's chosen, as on the canvas.
struct SettingsSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var icon: (Value) -> Icon? = { _ in nil }

    var body: some View {
        EqualWidths(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isOn = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    if let icon = icon(option.value) {
                        HStack(spacing: 6) {
                            icon.image
                                .font(.system(size: 13))
                                .foregroundStyle(isOn ? Color.primary : SettingsColors.note)
                            Text(option.title)
                        }
                    } else {
                        Text(option.title)
                    }
                }
                .buttonStyle(SegmentStyle(isOn: isOn))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(SettingsColors.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct SegmentStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SettingsColors.surface)
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(SettingsColors.line, lineWidth: 0.5)
                        }
                }
            }
            .opacity(configuration.isPressed && !isOn ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Lays its views out in a row, each as wide as the widest of them.
private struct EqualWidths: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.map(\.height).max() ?? 0
        return CGSize(width: width * CGFloat(subviews.count) + spacing * CGFloat(max(0, subviews.count - 1)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = CGFloat(max(1, subviews.count))
        let width = (bounds.width - spacing * (count - 1)) / count
        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index) * (width + spacing)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

/// A thin track in ink with a white knob, and the value after it.
struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String

    private static let trackWidth: CGFloat = 180
    private static let knob: CGFloat = 18

    var body: some View {
        HStack(spacing: 10) {
            track
            Text(label(value))
                .monospacedDigit()
                .foregroundStyle(SettingsColors.note)
                .frame(width: 36, alignment: .trailing)
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step)
                .accessibilityValue(label(value))
        }
    }

    private var fraction: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private var track: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(SettingsColors.line)
                .frame(height: 4)
            Capsule()
                .fill(SettingsColors.ink)
                .frame(width: Self.trackWidth * fraction, height: 4)
            Circle()
                .fill(.white)
                .frame(width: Self.knob, height: Self.knob)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                .overlay {
                    Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5)
                }
                .offset(x: Self.trackWidth * fraction - Self.knob / 2)
        }
        .frame(width: Self.trackWidth, height: Self.knob)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in set(fromX: drag.location.x) }
        )
    }

    private func set(fromX x: CGFloat) {
        let fraction = min(max(x / Self.trackWidth, 0), 1)
        let raw = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
        let snapped = (raw / step).rounded() * step
        let clamped = min(max(snapped, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
    }
}

// MARK: Buttons

/// The canvas's buttons in Settings: soft gray, or solid ink for the one
/// that matters most on its row, such as Install…. The small ones sit inside
/// lists, beside an agent's name.
struct SettingsButtonStyle: ButtonStyle {
    enum Kind {
        case secondary
        case primary
    }

    var kind = Kind.secondary
    var isSmall = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: isSmall ? 7 : 9, style: .continuous)
        configuration.label
            .font(.system(size: isSmall ? 12 : 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, isSmall ? 9 : 12)
            .frame(height: isSmall ? 24 : 28)
            .foregroundStyle(kind == .primary ? DialogColors.onInk : .primary)
            .background(kind == .primary ? SettingsColors.ink : SettingsColors.secondaryButton, in: shape)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static func settings(_ kind: SettingsButtonStyle.Kind = .secondary, small: Bool = false) -> SettingsButtonStyle {
        SettingsButtonStyle(kind: kind, isSmall: small)
    }
}

/// Words in gray that do something, such as Reset to Roga's, without a button
/// around them.
struct SettingsLinkStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(SettingsColors.note)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: Choosing and typing

/// The chosen value and a chevron, which open a menu of the choices with a
/// check beside the chosen one, as the canvas's popups do. It has no border,
/// so it reads as part of its row.
struct SettingsPopup<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    /// Gray words after a value's title, as in "Default · gpt-6-astra", where
    /// Default means something only the agent knows.
    var detail: (Value) -> String? = { _ in nil }
    /// A command after the choices, for a value that isn't one of them, such
    /// as a model's name to type.
    var more: (title: String, action: () -> Void)?
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu {
            SettingsChoices(selection: $selection, options: options, detail: detail)
            if let more {
                Divider()
                Button(more.title, action: more.action)
            }
        } label: {
            HStack(spacing: 6) {
                label
                SettingsChevron()
            }
            .lineLimit(1)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 28)
            .background(isHovering ? SettingsColors.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { isHovering = $0 && isEnabled }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityValue(title(of: selection))
    }

    private var label: Text {
        let title = Text(title(of: selection))
        guard let detail = detail(selection) else { return title }
        return Text("\(title) \(Text("· \(detail)").foregroundStyle(SettingsColors.note))")
    }

    private func title(of value: Value) -> String {
        options.first { $0.value == value }?.title ?? ""
    }
}

/// The canvas's select: a box with a line around it, as wide as it's asked to
/// be, with the chosen value at its start and the chevron at its end, for a
/// choice that matters more than a popup's.
struct SettingsSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    /// What it says when there's nothing to choose.
    var emptyTitle = ""
    var width: CGFloat = 200
    @Environment(\.isEnabled) private var isEnabled

    /// What it shows: the chosen value's title, or `emptyTitle`. VoiceOver
    /// reads it as the value too, because the row names the select by its
    /// setting, which hides the menu's own label.
    var shownTitle: String {
        options.first { $0.value == selection }?.title ?? emptyTitle
    }

    var body: some View {
        Menu {
            SettingsChoices(selection: $selection, options: options)
        } label: {
            HStack(spacing: 8) {
                Text(shownTitle)
                    .foregroundStyle(options.isEmpty ? SettingsColors.note : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SettingsChevron()
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(width: width, height: 32)
            .background(SettingsColors.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(SettingsColors.line, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(options.isEmpty)
        .accessibilityValue(shownTitle)
    }
}

/// The items of a popup's menu, with a check beside the chosen one.
struct SettingsChoices<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var detail: (Value) -> String? = { _ in nil }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.value) { option in
                Text(detail(option.value).map { "\(option.title) · \($0)" } ?? option.title)
                    .tag(option.value)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// The check before what's chosen, where a choice of one is a list of rows:
/// setup's menus of programs and Generate's popover. Roga marks a choice of
/// one with a check everywhere, as its menus do, rather than a radio. Every
/// row keeps the check's column, so their names line up.
struct ChoiceCheck: View {
    let isChecked: Bool

    var body: some View {
        Icon.check.image
            .font(.system(size: 12.5, weight: .semibold))
            .opacity(isChecked ? 1 : 0)
            .frame(width: 16, height: 18)
            .accessibilityHidden(true)
    }
}

/// The small chevron at the end of a popup or a select.
struct SettingsChevron: View {
    var body: some View {
        Icon.dropdown.image
            .font(.system(size: 11))
            .foregroundStyle(SettingsColors.note)
            .accessibilityHidden(true)
    }
}

/// A one-line box to type in, with a line around it, in the code font for
/// what's typed as arguments.
struct SettingsTextField: View {
    @Binding var text: String
    var placeholder = ""
    var width: CGFloat = 240
    var isMonospaced = false

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(SettingsColors.note))
            .textFieldStyle(.plain)
            .font(isMonospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .autocorrectionDisabled()
            .padding(.horizontal, 11)
            .frame(width: width, height: 32)
            .background(SettingsColors.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(SettingsColors.line, lineWidth: 1)
            }
    }
}

/// A box for a paragraph, as wide as its row, that grows with what's typed in
/// it from the height of four lines.
///
/// It's a text editor rather than a field, so that Return starts a new line,
/// as in the canvas's textarea: in a field, Return would end the editing and
/// type nothing. It shows every line rather than scroll, and it works out
/// their height itself, because in the Settings sheet the text view reports
/// the height it had before its text was laid out, and the box would cut the
/// fourth line in half with no way to scroll to the rest.
struct SettingsTextArea: View {
    @Binding var text: String
    let label: String

    @State private var width: CGFloat = 0

    static let fontSize: CGFloat = 13
    /// The canvas's lines are 1.45 times the font apart.
    static let lineSpacing: CGFloat = 3.3
    /// The room the text view keeps beside each line.
    static let linePadding: CGFloat = 5

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: Self.fontSize))
            .lineSpacing(Self.lineSpacing)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: Self.textHeight(text, width: width))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .accessibilityLabel(label)
            // The text view keeps 5 points beside each line, so the text
            // starts 12 points in, as on the canvas.
            .padding(EdgeInsets(top: 9, leading: 7, bottom: 9, trailing: 7))
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(SettingsColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(SettingsColors.line, lineWidth: 1)
            }
    }

    /// How tall `text` is in a text view `width` points wide, with a line
    /// for the empty one after a final new line, where the insertion point
    /// goes. Before the box knows its width, it's one line.
    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let lineWidth = width - 2 * linePadding
        guard lineWidth > fontSize else {
            return ceil(NSAttributedString(string: " ", attributes: attributes).size().height + lineSpacing)
        }
        let measured = text.isEmpty || text.hasSuffix("\n") ? text + " " : text
        let bounds = NSAttributedString(string: measured, attributes: attributes).boundingRect(
            with: CGSize(width: lineWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // The last line's spacing too, so its descenders are never cut.
        return ceil(bounds.height + lineSpacing)
    }
}

// MARK: Cards and lists

/// The exact command something on the page runs (decision 29), in the
/// dialogs' dark block, with the rounded corners the canvas gives it in
/// Settings, where it sits among the rows rather than along an edge.
struct SettingsCommand: View {
    let lines: [TerminalLine]

    var body: some View {
        CommandBlock(lines: lines)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A gray card of facts, each a name in the code font and what it means,
/// such as the flags Roga always gives an agent.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            content
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A fact on a `SettingsCard`: its name in the code font in a column of its
/// own, and what it means in gray beside it.
struct SettingsCardRow<Value: View>: View {
    let name: String
    var nameWidth: CGFloat = 200
    /// Whether the two sit on one line's middle rather than on its baseline,
    /// for a value that starts with a mark.
    var centersValue = false
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: centersValue ? .center : .firstTextBaseline, spacing: 12) {
            Text(verbatim: name)
                .font(.system(size: 11.5, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: nameWidth, alignment: .leading)
            value
                .font(.system(size: 12.5))
                .foregroundStyle(SettingsColors.note)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The canvas's lines are 1.4 times the font apart.
        .lineSpacing(2.5)
        .accessibilityElement(children: .combine)
    }
}

extension SettingsCardRow where Value == Text {
    init(_ name: String, nameWidth: CGFloat = 200, _ value: String) {
        self.init(name: name, nameWidth: nameWidth) { Text(value) }
    }
}

/// Rows with a thin line around them and between them, such as the agents
/// Roga found.
struct SettingsList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle()
                            .fill(SettingsColors.hairline)
                            .frame(height: 1)
                    }
                    row
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(SettingsColors.hairline, lineWidth: 1)
        }
    }
}

/// Something worth knowing about a page, on a gray card with an icon, such as
/// why the sidebar can't show marks.
struct SettingsNotice<Actions: View>: View {
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Icon.info.image
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsColors.note)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(SettingsColors.note)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(SettingsColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension AttributedString {
    /// Words with names in them that are typed rather than said, such as
    /// PATH, each set in the code font as the canvas's `.mono` sets them. They
    /// keep the words' size and color and have no gray ground, which the
    /// canvas keeps for a key, such as a command to run.
    static func settingsWords(_ text: String, typedNames names: [String]) -> AttributedString {
        var words = AttributedString(text)
        for name in names {
            var start = words.startIndex
            while let found = words[start...].range(of: name) {
                words[found].font = .system(size: 12.5, design: .monospaced)
                start = found.upperBound
            }
        }
        return words
    }

    /// Words with short commands in them, each set as the canvas sets a key:
    /// in the code font on a gray ground, as in "Each hook runs `roga hook`".
    static func settingsWords(_ parts: [(text: String, isCode: Bool)]) -> AttributedString {
        var words = AttributedString()
        for part in parts {
            guard part.isCode else {
                words += AttributedString(part.text)
                continue
            }
            // A word joiner after each hyphen, so that a line doesn't break
            // inside an option and look like two words.
            var code = AttributedString("\u{2009}" + part.text.replacingOccurrences(of: "-", with: "-\u{2060}") + "\u{2009}")
            code.font = .system(size: 11.5, design: .monospaced)
            code.backgroundColor = SettingsColors.card
            words += code
        }
        return words
    }
}
