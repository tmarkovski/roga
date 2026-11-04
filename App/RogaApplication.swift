import AppKit
import Sparkle
import SwiftUI
import RogaUI

@main
struct RogaApplication: App {
    // Sparkle starts only when the Info.plist has the public key that release
    // builds are signed with, so development builds never look for updates.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// The git every window uses, which Roga finds once at launch.
    @State private var gitProvider = GitProvider()
    /// The repositories in the sidebar, which every window lists.
    @State private var repositories = RepositoryList()

    init() {
        // Repositories are switched in the sidebar (decision 13).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        // SwiftUI saves the worktree each window shows, and restores it with
        // the window when macOS restores windows.
        WindowGroup(id: "workspace", for: WorkspaceWindow.self) { $window in
            WorkspaceView(window: $window)
                .environment(gitProvider)
                .environment(repositories)
        }
        // Wide enough for the sidebar, the refs panel and the panels between
        // them.
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updaterController.updater)
            }
            RepositoryCommands(list: repositories)
        }
        Settings {
            SettingsView()
        }
        // For looking at the house's animations up close. It's listed in the
        // Window menu.
        Window("House Animations", id: "house-animations") {
            HouseAnimationDemo()
        }
        .defaultSize(width: 1000, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
