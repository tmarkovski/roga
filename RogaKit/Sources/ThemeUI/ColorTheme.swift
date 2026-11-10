import AppKit
import Observation
import Synchronization

/// Which colors Roga gives what carries meaning, chosen in Settings › Appearance
/// (decision 71). It's apart from `AppTheme`, which chooses light or dark, and
/// each theme has colors for both.
public enum ColorTheme: String, CaseIterable, Identifiable, Sendable {
    case monokai
    case xcode

    public var id: Self { self }

    public static let key = "colorTheme"

    public var title: String {
        switch self {
        case .monokai: "Monokai"
        case .xcode: "Xcode"
        }
    }

    public var colors: ThemeColors {
        switch self {
        case .monokai: .monokai
        case .xcode: .xcode
        }
    }

    private static let chosen = Mutex(ColorTheme.monokai)

    /// The theme in use. Anything can read it, because a diff's text is built
    /// away from the main actor and a color resolves wherever it's drawn.
    public static var current: ColorTheme {
        chosen.withLock { $0 }
    }

    /// The theme in use, for SwiftUI: a view whose body reads it draws again
    /// when it changes.
    @MainActor public static var observed: ColorTheme {
        ThemeObservation.shared.theme
    }

    /// The theme `defaults` has, or Monokai when it has none it knows.
    public static func stored(in defaults: UserDefaults = .standard) -> ColorTheme {
        defaults.string(forKey: key).flatMap(ColorTheme.init(rawValue:)) ?? .monokai
    }

    /// Makes this the theme in use, and draws every window again in it.
    @MainActor public func use() {
        guard Self.chosen.withLock({ theme in
            defer { theme = self }
            return theme != self
        }) else { return }
        ThemeObservation.shared.theme = self
        Self.redrawWindows()
    }

    /// Uses the theme in user defaults. The app does this as it starts, before
    /// its first window shows.
    @MainActor public static func useStored() {
        stored().use()
    }

    /// A color that's always the current theme's, which AppKit views can keep:
    /// it resolves each time it's drawn, so a view only has to draw again.
    public static func following(alpha: CGFloat = 1, _ role: @escaping @Sendable (ThemeColors) -> ThemeColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let color = role(current.colors).resolved(for: appearance)
            return alpha < 1 ? color.withAlphaComponent(alpha) : color
        }
    }

    /// AppKit views draw again with the new colors, and the views that keep a
    /// color in a layer set it again, as they do when the appearance changes.
    @MainActor private static func redrawWindows() {
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            view.viewDidChangeEffectiveAppearance()
            view.subviews.forEach(redraw)
        }
        for window in NSApplication.shared.windows {
            (window.contentView?.superview ?? window.contentView).map(redraw)
        }
    }
}

/// What SwiftUI watches for the theme.
@MainActor @Observable final class ThemeObservation {
    static let shared = ThemeObservation()

    var theme = ColorTheme.current
}
