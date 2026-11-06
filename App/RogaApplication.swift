import AppKit
import SwiftUI
import RogaUI

@main
struct RogaApplication: App {
    /// Sparkle, which finds new versions of Roga and installs them.
    private let sparkle: SparkleUpdates
    /// What every window and Settings show of Sparkle: a new version waiting,
    /// and whether it checks and downloads by itself.
    @State private var updates: Updates

    /// The git every window uses, which Roga finds once at launch.
    @State private var gitProvider = GitProvider()
    /// The repositories in the sidebar, which every window lists.
    @State private var repositories = RepositoryList()
    /// Settings asked for with no window open, which the next window shows.
    @State private var settingsRequest = SettingsRequest()
    /// The agents' command-line tools, which every window uses, and which
    /// start once git is ready (decision 41).
    @State private var agents = AgentProvider(supportFolder: AgentProvider.standardSupportFolder, helperPath: AgentProvider.bundledHelperPath)
    /// What the agents' hooks say they're doing, for the sidebar's marks.
    @State private var agentMonitor = AgentMonitor(supportFolder: AgentProvider.standardSupportFolder)

    init() {
        // Repositories are switched in the sidebar (decision 13).
        NSWindow.allowsAutomaticWindowTabbing = false
        let updates = Updates()
        _updates = State(initialValue: updates)
        sparkle = SparkleUpdates(updates: updates)
    }

    var body: some Scene {
        // SwiftUI saves the worktree each window shows, and restores it with
        // the window when macOS restores windows.
        WindowGroup(id: "workspace", for: WorkspaceWindow.self) { $window in
            WorkspaceView(window: $window)
                .environment(gitProvider)
                .environment(repositories)
                .environment(settingsRequest)
                .environment(agents)
                .environment(agentMonitor)
                .environment(updates)
        }
        // Wide enough for the sidebar, the refs panel and the panels between
        // them.
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: sparkle.updater)
            }
            RepositoryCommands(list: repositories, agents: agents)
            SettingsCommands(request: settingsRequest)
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
