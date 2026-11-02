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

    /// The git every window uses, which yaga finds once at launch.
    @State private var gitProvider = GitProvider()

    init() {
        // yaga draws its own tabs (decision 10).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        // Each window shows the repository in the folder it's given, and
        // SwiftUI restores it with the window when yaga launches again.
        WindowGroup(id: "workspace", for: String.self) { $path in
            WorkspaceView(path: $path)
                .environment(gitProvider)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updaterController.updater)
            }
            RepositoryCommands()
        }
    }
}
