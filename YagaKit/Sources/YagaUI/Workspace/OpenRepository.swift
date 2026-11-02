import AppKit
import SwiftUI

/// Asks for a repository's folder with an open panel, and returns its path.
@MainActor
func chooseRepositoryFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose a repository, or any folder inside one."
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return (url.path(percentEncoded: false) as NSString).standardizingPath
}

extension FocusedValues {
    /// The folder the focused window shows, which only a window that doesn't
    /// show a repository yet offers, so that a repository opens there rather
    /// than in a new window.
    @Entry var emptyWindowPath: Binding<String?>?
}
