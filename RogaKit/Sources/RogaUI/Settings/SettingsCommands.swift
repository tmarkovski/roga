import Observation
import SwiftUI

/// Settings… in the app menu, with ⌘,. It shows Settings as a sheet on the
/// focused Roga window, the way Roga's dialogs show, rather than in a window of
/// the system's own.
public struct SettingsCommands: Commands {
    let request: SettingsRequest
    @FocusedValue(\.showsSettings) private var showsSettings
    @Environment(\.openWindow) private var openWindow

    public init(request: SettingsRequest) {
        self.request = request
    }

    public var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                if let showsSettings {
                    showsSettings.wrappedValue = true
                } else {
                    // With no Roga window in front, a new one opens and shows
                    // Settings as soon as it appears.
                    request.isPending = true
                    openWindow(value: WorkspaceWindow())
                }
            }
            .keyboardShortcut(",")
        }
    }
}

/// Settings asked for while no Roga window was in front, for the next window
/// that appears to show.
@MainActor @Observable public final class SettingsRequest {
    var isPending = false

    public init() {}
}

extension FocusedValues {
    /// Whether the focused window shows Settings.
    @Entry var showsSettings: Binding<Bool>?
}
