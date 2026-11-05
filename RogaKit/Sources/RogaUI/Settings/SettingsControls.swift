import AppKit
import SwiftUI

/// The colors of the Settings sheet, from the design canvas's Settings boards,
/// which use the dialogs' (decision 29) so that the two look like one family.
enum SettingsColors {
    static let surface = DialogColors.surface
    static let card = DialogColors.card
    /// The gray of help under a setting, and of icons that aren't selected.
    static let note = DialogColors.note
    static let ink = DialogColors.ink
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

/// A group of settings under a heading, with a thin line between its rows and
/// no card around them.
struct SettingsSection<Aside: View, Content: View>: View {
    let title: String
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
/// right.
struct SettingsRow<Control: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let help {
                    Text(help)
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .foregroundStyle(SettingsColors.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .fixedSize()
                .accessibilityLabel(title)
                .accessibilityHint(help ?? "")
        }
        .padding(.vertical, 10)
        .frame(minHeight: help == nil ? 46 : 56)
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
/// one that's chosen raised in white.
struct SettingsSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        EqualWidths(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button(option.title) {
                    selection = option.value
                }
                .buttonStyle(SegmentStyle(isOn: selection == option.value))
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
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
