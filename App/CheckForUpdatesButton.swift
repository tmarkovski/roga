import Combine
import Sparkle
import SwiftUI

/// The Check for Updates command in the app menu. It lives in the app target
/// rather than with the other commands in YagaUI, because only the app target
/// links Sparkle.
struct CheckForUpdatesButton: View {
    let updater: SPUUpdater
    @State private var canCheckForUpdates = false

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!canCheckForUpdates)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheckForUpdates = $0 }
    }
}
