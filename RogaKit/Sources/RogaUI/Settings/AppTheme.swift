import AppKit
import IconUI

/// Whether Roga looks light or dark, chosen in Settings › Appearance. It
/// follows the system's appearance unless someone chooses otherwise.
public enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: Self { self }

    static let key = "theme"

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var icon: Icon {
        switch self {
        case .system: .systemTheme
        case .light: .lightTheme
        case .dark: .darkTheme
        }
    }

    /// What the application's appearance becomes, which every window, sheet
    /// and menu takes. Nil follows the system's.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The theme `defaults` has, or System when it has none it knows.
    static func stored(in defaults: UserDefaults = .standard) -> AppTheme {
        defaults.string(forKey: key).flatMap(AppTheme.init(rawValue:)) ?? .system
    }

    /// Gives every window, sheet and menu the theme's appearance at once.
    @MainActor func apply(to application: NSApplication = .shared) {
        application.appearance = appearance
    }

    /// Applies the theme in user defaults. The app does this as it starts,
    /// before its first window shows, so that a dark theme doesn't show a
    /// light window first.
    @MainActor public static func applyStored() {
        stored().apply()
    }
}
