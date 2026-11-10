import AppKit
import Foundation
import Testing
@testable import RogaUI

/// The theme chosen in Settings › Appearance: how it's stored, what it sets
/// on the application, and where Settings shows it.
@MainActor
struct AppThemeTests {
    @Test func itFollowsTheSystemUntilSomeoneChooses() throws {
        let (defaults, name) = AgentTestSupport.defaults()
        defer { AgentTestSupport.remove(defaults, named: name) }
        #expect(AppTheme.stored(in: defaults) == .system)
        defaults.set("dark", forKey: AppTheme.key)
        #expect(AppTheme.stored(in: defaults) == .dark)
        defaults.set("light", forKey: AppTheme.key)
        #expect(AppTheme.stored(in: defaults) == .light)
        // Something Settings wouldn't write, such as an old or misspelled value.
        defaults.set("sepia", forKey: AppTheme.key)
        #expect(AppTheme.stored(in: defaults) == .system)
    }

    @Test func eachThemeSetsTheApplicationsAppearance() {
        #expect(AppTheme.system.appearance == nil)
        #expect(AppTheme.light.appearance?.name == .aqua)
        #expect(AppTheme.dark.appearance?.name == .darkAqua)

        let application = NSApplication.shared
        let before = application.appearance
        defer { application.appearance = before }
        AppTheme.dark.apply(to: application)
        #expect(application.appearance?.name == .darkAqua)
        #expect(application.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        AppTheme.light.apply(to: application)
        #expect(application.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua)
        AppTheme.system.apply(to: application)
        #expect(application.appearance == nil)
    }

    @Test func settingsShowsItFirstOnAppearance() {
        #expect(AppTheme.allCases.map(\.title) == ["System", "Light", "Dark"])
        #expect(SettingsGroup.allCases.first { $0.page == .appearance } == .interface)
        #expect(SettingsGroup.interface.items == [.theme, .colors, .codeFont])
        #expect(SettingsItem.theme.title == "Theme")
        // Search finds it by any of its choices, and by what people call them.
        for query in ["theme", "Dark", "light mode", "System", "Appearance"] {
            #expect(SettingsItem.theme.matches(query), "\(query)")
        }
    }

    /// The color themes are under Theme, and search finds them by name
    /// (decision 71).
    @Test func settingsShowsTheColorThemesUnderTheTheme() {
        #expect(SettingsItem.colors.title == "Colors")
        for query in ["Monokai", "xcode", "color theme", "graph"] {
            #expect(SettingsItem.colors.matches(query), "\(query)")
        }
        #expect(!SettingsItem.colors.matches("light mode"))
    }

    /// The code font comes after the colors, under the preview it shows in,
    /// with its size on the same row. Search finds it by what people call
    /// either (decision 73).
    @Test func settingsShowsTheCodeFontUnderThePreview() {
        #expect(SettingsItem.codeFont.title == "Code font")
        #expect(SettingsItem.codeFont.help == "For diffs and conflict resolution.")
        #expect(SettingsGroup.interface.items.last == .codeFont)
        for query in ["font", "monospaced", "SF Mono", "typeface", "diff", "font size", "text size", "points"] {
            #expect(SettingsItem.codeFont.matches(query), "\(query)")
        }
        #expect(SettingsGroup.found("code font").map(\.items) == [[.codeFont]])
        #expect(SettingsGroup.found("font size").map(\.items) == [[.codeFont]])
    }
}
