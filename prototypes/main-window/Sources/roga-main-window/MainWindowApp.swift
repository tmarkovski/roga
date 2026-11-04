import AppKit
import SwiftUI

@main
struct MainWindowApp: App {
    init() {
        // Roga draws its own tabs (decision 10).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup(id: WorkspaceModel.sceneID) {
            WorkspaceView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        // Without this, a launch after quitting with no windows can show none.
        .defaultLaunchBehavior(.presented)
        .commands { WorkspaceCommands() }
    }
}

struct WorkspaceFocusedKey: FocusedValueKey {
    typealias Value = WorkspaceModel
}

extension FocusedValues {
    var workspace: WorkspaceModel? {
        get { self[WorkspaceFocusedKey.self] }
        set { self[WorkspaceFocusedKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { workspace?.chooseAndOpen() }
                .keyboardShortcut("t")
                .disabled(workspace == nil)
            Button("New Window") { openWindow(id: WorkspaceModel.sceneID) }
                .keyboardShortcut("n")
            Divider()
            Button("Close Tab") { workspace?.closeSelectedTab() }
                .keyboardShortcut("w")
                .disabled(workspace == nil)
        }
        CommandGroup(before: .windowList) {
            Button("Show Next Tab") { workspace?.selectAdjacent(1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(workspace == nil)
            Button("Show Previous Tab") { workspace?.selectAdjacent(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(workspace == nil)
            Button("Move Tab to New Window") {
                if let workspace, let selection = workspace.selection {
                    workspace.moveToNewWindow(selection, using: openWindow)
                }
            }
            .disabled((workspace?.tabs.count ?? 0) < 2)
            Divider()
            ForEach(1..<10) { number in
                Button(number == 9 ? "Show Last Tab" : "Show Tab \(number)") { workspace?.select(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    .disabled(workspace == nil)
            }
            Divider()
        }
    }
}

/// The preview reads its repositories from the environment. Paths passed as
/// launch arguments make AppKit treat the launch as a request to open files,
/// and SwiftUI then doesn't open its first window.
enum LaunchOptions {
    private static let environment = ProcessInfo.processInfo.environment
    private static var openAllPending = environment["ROGA_PREVIEW_OPEN_ALL"] == "1"

    static let repositories: [URL] = (environment["ROGA_PREVIEW_REPOS"] ?? "")
        .split(separator: "|")
        .map(String.init)
        .filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        .map(RepositoryURL.make)

    /// Returns true once when `--open-all` was passed.
    static func claimOpenAll() -> Bool {
        defer { openAllPending = false }
        return openAllPending
    }
}

nonisolated enum RepositoryURL {
    static func make(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
    }

    static func path(of url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

enum RepositoryOpener {
    static func choose(_ open: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.message = "Choose a folder inside a Git repository."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let top = await Git.run(["rev-parse", "--show-toplevel"], in: url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !top.isEmpty { open(RepositoryURL.make(top)) }
        }
    }
}
