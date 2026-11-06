import AppKit

/// A terminal that Open in Terminal can use, chosen on Settings' General page.
/// These are the ones that open a new window or tab in a folder they're handed,
/// the way Finder hands one over.
enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal = "com.apple.Terminal"
    case iTerm = "com.googlecode.iterm2"
    case ghostty = "com.mitchellh.ghostty"
    case warp = "dev.warp.Warp-Stable"

    /// Where the choice is kept, as the app's bundle identifier.
    static let key = "terminal"

    var id: Self { self }

    var name: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        }
    }

    /// Where it's installed, or nil when it isn't.
    var url: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue)
    }

    /// The terminals on this Mac, which always include Terminal.
    static var installed: [TerminalApp] {
        allCases.filter { $0 == .terminal || $0.url != nil }
    }

    /// The one chosen in Settings, or Terminal while that's gone from this Mac.
    static func chosen(in defaults: UserDefaults = .standard) -> TerminalApp {
        defaults.string(forKey: key).flatMap(TerminalApp.init).flatMap { $0.url == nil ? nil : $0 } ?? .terminal
    }
}

func openInTerminal(_ path: String) {
    guard let terminal = TerminalApp.chosen().url ?? TerminalApp.terminal.url else { return }
    NSWorkspace.shared.open([URL(filePath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
}
