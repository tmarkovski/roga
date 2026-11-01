import AppKit
import Sparkle
import SwiftUI
import YagaUI

@main
struct YagaApplication: App {
    // Sparkle starts only when the Info.plist has the public key that release
    // builds are signed with, so development builds never look for updates.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        // yaga draws its own tabs (decision 10).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup(id: "workspace") {
            WorkspaceView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updaterController.updater)
            }
        }
    }
}
