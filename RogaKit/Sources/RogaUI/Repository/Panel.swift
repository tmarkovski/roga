import AppKit
import HistoryUI
import IconUI
import SwiftUI

/// The colors of panels. Surfaces are plain, sections are separated by thin
/// lines, and selection is a soft gray rather than the accent color
/// (docs/main-window.md).
enum Palette {
    static let surface = gray(light: 1.0, dark: 0.135)
    static let separator = gray(light: 0.885, dark: 0.225)
    /// The fill under a row or an icon button while the pointer is over it.
    /// It darkens whatever is behind it, such as the sidebar's material.
    static let hover = Color.primary.opacity(0.075)
    /// The fill under a selected row.
    static let selection = Color.primary.opacity(0.11)
    /// The strongest mark that isn't a color: the main button in a dialog, what's
    /// selected on the rail (decision 36), and a line that's about to be dragged.
    static let ink = gray(light: 0.102, dark: 0.925)
    /// Words and icons on top of `ink`.
    static let onInk = gray(light: 1.0, dark: 0.086)
    /// The brand's orange, for what a click would run right now.
    static let action = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 240 / 255, green: 129 / 255, blue: 63 / 255, alpha: 1)
            : NSColor(srgbRed: 201 / 255, green: 68 / 255, blue: 2 / 255, alpha: 1)
    })
    /// The same orange behind white text, which stays dark enough to read in both
    /// appearances.
    static let actionFill = Color(nsColor: NSColor(srgbRed: 201 / 255, green: 68 / 255, blue: 2 / 255, alpha: 1))

    /// The current branch, in the color of its badge in history (decision 27).
    static let current = Color(nsColor: GitColors.current)
    /// What was added, and commits ahead of the upstream.
    static let green = Color(nsColor: GitColors.green)
    /// What was removed, and commits behind the upstream.
    static let red = Color(nsColor: GitColors.red)
    /// What was moved or copied.
    static let blue = Color(nsColor: GitColors.blue)

    static func gray(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }
}

/// A plain rectangle with a 40-point header: a title or sub-tabs on the
/// left, and the panel's commands on the right.
struct Panel<Leading: View, Trailing: View, Content: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                HStack(spacing: 4) {
                    leading
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, 10)
            .frame(height: PanelSplitLayout.headerHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The panel is never taller than the room it's given, even when
                // what it shows can't get that short, as when it's minimized to
                // its header. What doesn't fit runs off its bottom edge, so that
                // its header lines up with the one beside it.
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
        .background(Palette.surface)
    }
}

/// Two panels, one above the other, with a thin line between them that drags
/// to resize them. The lower one keeps its height as the window changes size,
/// unless that would make the upper one too short. It can also cover the upper
/// one, or fold down to its header.
struct PanelSplit<Upper: View, Lower: View>: View {
    /// The lower panel's height, or 0 until someone has dragged it, which leaves
    /// the upper panel `upperHeightUntilDragged`.
    @Binding var lowerHeight: Double
    @Binding var lowerSize: LowerPanelSize
    var upperHeightUntilDragged = 0.0
    @ViewBuilder var upper: Upper
    @ViewBuilder var lower: Lower
    /// The lower panel's height when the current drag started.
    @State private var heightAtStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let layout = PanelSplitLayout(
                height: geometry.size.height,
                lowerHeight: lowerHeight,
                upperHeightUntilDragged: upperHeightUntilDragged,
                size: lowerSize
            )
            let isCovered = lowerSize == .maximized
            // Both panels stay in place while one covers the other, with no
            // height, so that what they show, such as where history is
            // scrolled to and the diff's place, is still there when they come
            // back.
            VStack(spacing: 0) {
                upper
                    .frame(height: layout.upper)
                    .opacity(isCovered ? 0 : 1)
                    .allowsHitTesting(!isCovered)
                    .accessibilityHidden(isCovered)
                PanelDivider(axis: .vertical) { moved in
                    let start = heightAtStart ?? layout.lower
                    heightAtStart = start
                    let dragged = PanelSplitLayout.dragged(to: start - moved, in: geometry.size.height)
                    lowerSize = dragged.size
                    if let height = dragged.height { lowerHeight = height }
                } ended: {
                    heightAtStart = nil
                }
                .frame(height: isCovered ? 0 : nil)
                .opacity(isCovered ? 0 : 1)
                .allowsHitTesting(!isCovered)
                // A minimized panel keeps its header at the top, and what
                // doesn't fit under it is cut off rather than pushing it up.
                lower
                    .frame(height: layout.lower, alignment: .top)
                    .clipped()
            }
        }
    }
}

/// Two panels, side by side, with a thin line between them that drags to resize
/// them. The leading one keeps its width as the window changes size, unless
/// that would make the trailing one too narrow.
struct PanelColumns<Leading: View, Trailing: View>: View {
    @Binding var leadingWidth: Double
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    /// The leading panel's width when the current drag started.
    @State private var widthAtStart: Double?

    private static var minimumWidth: Double { 180 }

    var body: some View {
        GeometryReader { geometry in
            let widest = max(Self.minimumWidth, geometry.size.width - Self.minimumWidth - 1)
            let width = min(max(leadingWidth, Self.minimumWidth), widest)
            HStack(spacing: 0) {
                leading
                    .frame(width: width)
                PanelDivider(axis: .horizontal) { moved in
                    let start = widthAtStart ?? width
                    widthAtStart = start
                    leadingWidth = min(max(start + moved, Self.minimumWidth), widest)
                } ended: {
                    widthAtStart = nil
                }
                trailing
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The main content, and a panel beside it that shows and hides, with a thin
/// line between them that drags to resize the panel. The panel gets narrower
/// as the window does, to leave the main content its minimum, and goes back to
/// its width when there's room.
struct SidePanelColumns<Main: View, Side: View>: View {
    let isShown: Bool
    @Binding var width: Double
    let minimumWidth: Double
    let maximumWidth: Double
    let minimumMainWidth: Double
    @ViewBuilder var main: Main
    /// The panel, given how wide it is.
    @ViewBuilder var side: (Double) -> Side
    /// The panel's width when the current drag started.
    @State private var widthAtStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let widest = max(minimumWidth, min(maximumWidth, geometry.size.width - minimumMainWidth - 1))
            let shownWidth = min(max(width, minimumWidth), widest)
            HStack(spacing: 0) {
                main
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isShown {
                    PanelDivider(axis: .horizontal) { moved in
                        let start = widthAtStart ?? shownWidth
                        widthAtStart = start
                        width = min(max(start - moved, minimumWidth), widest)
                    } ended: {
                        widthAtStart = nil
                    }
                    // Like the line after the sidebar, it goes up to the top of
                    // the window.
                    .ignoresSafeArea(edges: .top)
                    side(shownWidth)
                        .frame(width: shownWidth)
                }
            }
        }
    }
}

/// The thin line between two panels, and the wider area around it that drags
/// it.
private struct PanelDivider: View {
    /// The direction the line moves in.
    let axis: Axis
    /// Says how far the line has moved during a drag.
    let moved: (Double) -> Void
    let ended: () -> Void
    @State private var isHovering = false
    @GestureState private var isDragging = false

    var body: some View {
        PanelLine(axis: axis, isPointerOver: isHovering, isDragging: isDragging)
            .overlay {
                // Easier to grab than the line, and over both panels.
                Color.clear
                    .frame(width: axis == .horizontal ? 9 : nil, height: axis == .vertical ? 9 : nil)
                    .contentShape(Rectangle())
                    .pointerStyle(axis == .vertical ? .rowResize : .columnResize)
                    .onHover { isHovering = $0 }
                    .gesture(
                        // The line moves during the drag, so measure from the window.
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .updating($isDragging) { _, isDragging, _ in isDragging = true }
                            .onChanged { moved(axis == .vertical ? $0.translation.height : $0.translation.width) }
                            .onEnded { _ in ended() }
                    )
            }
            .zIndex(1)
    }
}

/// A thin line between two panels that can be dragged. It stands out once the
/// pointer has rested on it for a moment, and while it's being dragged. A pointer
/// on its way past leaves it alone.
struct PanelLine: View {
    /// The direction the line moves in.
    let axis: Axis
    let isPointerOver: Bool
    var isDragging = false
    /// Where the line stands out from, for one at the edge of what draws it. Its
    /// extra thickness goes over the panels and doesn't move them.
    var alignment = Alignment.center
    @State private var hasRested = false

    private var standsOut: Bool { hasRested || isDragging }

    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            .overlay(alignment: alignment) {
                Rectangle()
                    .fill(Palette.ink)
                    .frame(width: axis == .horizontal ? 2 : nil, height: axis == .vertical ? 2 : nil)
                    .opacity(standsOut ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: standsOut)
                    .allowsHitTesting(false)
            }
            .task(id: isPointerOver) {
                guard isPointerOver else {
                    hasRested = false
                    return
                }
                guard (try? await Task.sleep(for: .milliseconds(200))) != nil else { return }
                hasRested = true
            }
    }
}

/// A thin icon that gets a rounded gray square while the pointer is over it,
/// for the commands in panel headers and the sidebar (docs/main-window.md).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    /// Whether it stays looking pressed, for as long as what it opened shows.
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        HoverIcon(isPressed: configuration.isPressed || isOn, size: size) {
            configuration.label
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
    static func icon(size: CGFloat) -> IconButtonStyle { IconButtonStyle(size: size) }
    static func icon(isOn: Bool) -> IconButtonStyle { IconButtonStyle(isOn: isOn) }
}

/// The small chevron that says whether what's under it shows, at the size and
/// weight of the one on the branch's chip. It turns a quarter of the way around
/// between its two directions. The animation goes no further than the chevron,
/// so what's under it still comes and goes at once. Both directions take the
/// same room, so that nothing beside it moves.
struct Chevron: View {
    let pointsDown: Bool
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        Icon.disclosure.image
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(pointsDown ? 0 : -90))
            .animation(reducesMotion ? nil : .easeInOut(duration: 0.18), value: pointsDown)
            .frame(width: 10, height: 10)
    }
}

/// An icon in a square that fills with gray while the pointer is over it.
/// Menus use it as their label, because they don't take a button style.
struct HoverIcon<Icon: View>: View {
    var isPressed = false
    var size: CGFloat = 28
    @ViewBuilder var icon: Icon
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        icon
            .font(.system(size: size >= 28 ? 14 : 12.5))
            .foregroundStyle(isHovering || isPressed ? .primary : .secondary)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size >= 28 ? 8 : 7, style: .continuous)
                    .fill(isPressed ? Palette.selection : isHovering ? Palette.hover : .clear)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 && isEnabled }
    }
}

/// The box that opens beside a panel's search button, which looks pressed while
/// it's open and closes it when pressed again. It's as tall and as round as the
/// buttons beside it. Its own button clears what's typed, and Escape closes it.
struct PanelSearchField: View {
    let prompt: String
    let label: String
    @Binding var text: String
    @Binding var wantsFocus: Bool
    /// How the search went, which goes at the end of the box.
    var note: String?
    /// What the down arrow does, if anything.
    var moveDown: (() -> Void)?
    /// What Return does, if anything, and whether Shift was held.
    var submit: ((_ isBackwards: Bool) -> Void)?
    let close: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onKeyPress(.downArrow) {
                    guard let moveDown else { return .ignored }
                    moveDown()
                    return .handled
                }
                .onKeyPress(keys: [.return], phases: [.down, .repeat]) { press in
                    guard let submit else { return .ignored }
                    submit(press.modifiers.contains(.shift))
                    return .handled
                }
                .onExitCommand(perform: close)
                .accessibilityLabel(label)
            if let note, !text.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if !text.isEmpty {
                Button("Clear", icon: .x) {
                    text = ""
                    isFocused = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.icon)
                .help("Clear")
            }
        }
        .padding(.leading, 8)
        .frame(height: 28)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.separator)
                .allowsHitTesting(false)
        }
        .onChange(of: wantsFocus, initial: true) {
            guard wantsFocus else { return }
            wantsFocus = false
            // The field can't take the keyboard until it's in the window, which
            // takes a moment when the command has just shown it.
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                isFocused = true
            }
        }
    }
}

extension KeyboardShortcut {
    /// The shortcut's symbols in the order menus show them, such as ⇧ ⌘ O,
    /// with a thin space between each, which reads better outside a menu.
    var symbols: String {
        var symbols: [String] = []
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }
        switch key {
        case .return: symbols.append("↩")
        case .upArrow: symbols.append("↑")
        case .downArrow: symbols.append("↓")
        default: symbols.append(String(key.character).uppercased())
        }
        return symbols.joined(separator: "\u{2009}")
    }
}
