import AppKit
import SwiftUI

/// The colors of panels. Surfaces are plain, sections are separated by thin
/// lines, and selection is a soft gray rather than the accent color
/// (docs/main-window.md).
enum Palette {
    static let surface = gray(light: 1.0, dark: 0.135)
    static let separator = gray(light: 0.885, dark: 0.225)

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
