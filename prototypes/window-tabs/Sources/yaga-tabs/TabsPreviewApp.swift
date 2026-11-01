import AppKit
import SwiftUI

@main
struct TabsPreviewApp: App {
    var body: some Scene {
        Window("Welcome to yaga", id: "welcome") {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)

        // Each repository is its own window. The windows join one tab bar,
        // so by default the user sees a single window with a tab per repository.
        WindowGroup("Repository", for: URL.self) { $root in
            if let root {
                RepositoryWindow(root: root)
                    .frame(minWidth: 900, minHeight: 500)
            } else {
                // The "+" button in the tab bar opens an empty window. Choosing a
                // repository here turns that tab into the repository's tab.
                EmptyTabView(root: $root)
            }
        }
        .defaultSize(width: 1280, height: 780)
        .commands { RepositoryCommands() }
    }
}

struct RepositoryCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") {
                RepositoryOpener.choose { openWindow(value: $0) }
            }
            .keyboardShortcut("o")
        }
    }
}

enum LaunchOptions {
    private static var openAllPending = CommandLine.arguments.contains("--open-all")

    /// Returns true once when `--open-all` was passed. macOS may restore windows
    /// from the last session instead of showing the welcome window, so whichever
    /// window appears first opens the repositories.
    static func claimOpenAll() -> Bool {
        defer { openAllPending = false }
        return openAllPending
    }

    static let repositories: [URL] = CommandLine.arguments.dropFirst()
        .filter { !$0.hasPrefix("-") }
        .filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        .map(RepositoryURL.make)
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

struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private let suggestions = LaunchOptions.repositories

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("yaga").font(.largeTitle.bold())
                Text("A preview of repositories as native window tabs")
                    .foregroundStyle(.secondary)
            }
            List(suggestions, id: \.self) { url in
                Button { open([url]) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent).fontWeight(.medium)
                        Text(RepositoryURL.path(of: url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 180)
            HStack {
                Button("Open Repository…") {
                    RepositoryOpener.choose { open([$0]) }
                }
                Spacer()
                Button("Open All as Tabs") { open(suggestions) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(suggestions.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            if LaunchOptions.claimOpenAll() { open(suggestions) }
        }
    }

    private func open(_ urls: [URL]) {
        WindowTabbing.debug("open \(urls.map(\.lastPathComponent))")
        for url in urls { openWindow(value: url) }
        dismissWindow(id: "welcome")
    }
}

struct EmptyTabView: View {
    @Binding var root: URL?

    var body: some View {
        ContentUnavailableView {
            Label("No Repository", systemImage: "folder")
        } description: {
            Text("Open a repository in this tab.")
        } actions: {
            Button("Open Repository…") {
                RepositoryOpener.choose { root = $0 }
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .background(TabConfigurator(toolTip: "", changeSummary: nil))
    }
}
