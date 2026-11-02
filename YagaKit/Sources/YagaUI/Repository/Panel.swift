import AppKit
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
                leading
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.surface)
    }
}

/// Two panels, one above the other, with a thin line between them that drags
/// to resize them. The lower one keeps its height as the window changes size,
/// unless that would make the upper one too short.
struct PanelSplit<Upper: View, Lower: View>: View {
    @Binding var lowerHeight: Double
    @ViewBuilder var upper: Upper
    @ViewBuilder var lower: Lower
    /// The lower panel's height when the current drag started.
    @State private var heightAtStart: Double?

    private static var minimumHeight: Double { 100 }

    var body: some View {
        GeometryReader { geometry in
            let tallest = max(Self.minimumHeight, geometry.size.height - Self.minimumHeight - 1)
            let height = min(max(lowerHeight, Self.minimumHeight), tallest)
            VStack(spacing: 0) {
                upper
                    .frame(maxHeight: .infinity)
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1)
                    .overlay {
                        // Easier to grab than the line, and over both panels.
                        Color.clear
                            .frame(height: 9)
                            .contentShape(Rectangle())
                            .pointerStyle(.rowResize)
                            .gesture(
                                // The line moves during the drag, so measure from the window.
                                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                    .onChanged { drag in
                                        let start = heightAtStart ?? height
                                        heightAtStart = start
                                        lowerHeight = min(max(start - drag.translation.height, Self.minimumHeight), tallest)
                                    }
                                    .onEnded { _ in heightAtStart = nil }
                            )
                    }
                    .zIndex(1)
                lower
                    .frame(height: height)
            }
        }
    }
}

/// A thin icon that gets a rounded gray square while the pointer is over it,
/// for the commands in panel headers and the sidebar (docs/main-window.md).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        HoverIcon(isPressed: configuration.isPressed, size: size) {
            configuration.label
        }
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
    static func icon(size: CGFloat) -> IconButtonStyle { IconButtonStyle(size: size) }
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
            .foregroundStyle(isHovering ? .primary : .secondary)
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

extension KeyboardShortcut {
    /// The shortcut's symbols in the order menus show them, such as ⇧ ⌘ O,
    /// with a thin space between each, which reads better outside a menu.
    var symbols: String {
        var symbols: [String] = []
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }
        symbols.append(String(key.character).uppercased())
        return symbols.joined(separator: "\u{2009}")
    }
}
