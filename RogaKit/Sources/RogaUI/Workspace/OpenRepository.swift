import AppKit
import SwiftUI

/// Asks for a repository's folder with an open panel, and returns its path.
///
/// - Parameter near: A folder that's gone, for the panel to start in what's left
///   of the folders it was in, which is where a moved folder usually is.
@MainActor
func chooseRepositoryFolder(message: String = "Choose a repository, or any folder inside one.", near: String? = nil) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = message
    if let near, let start = nearestExistingFolder(above: near) {
        panel.directoryURL = URL(filePath: start, directoryHint: .isDirectory)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return (url.path(percentEncoded: false) as NSString).standardizingPath
}

/// The closest folder above `path` that still exists.
func nearestExistingFolder(above path: String) -> String? {
    var folder = (path as NSString).deletingLastPathComponent
    var isDirectory: ObjCBool = false
    while !folder.isEmpty, folder != "/" {
        if FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue { return folder }
        folder = (folder as NSString).deletingLastPathComponent
    }
    return nil
}

/// Asks for a folder and adds its repository to the sidebar, then passes
/// the worktree the folder is in to `select`. It explains in a dialog when
/// the folder isn't in a repository.
@MainActor
func openRepository(list: RepositoryList, select: @escaping (WorktreeSelection) -> Void) {
    guard let folder = chooseRepositoryFolder() else { return }
    Task {
        do {
            select(try await list.add(folder: folder))
        } catch {
            showAlert("Can't open this folder", error)
        }
    }
}

/// Asks where a repository that can't be found is now, and passes the
/// worktree to select to `select`. Its linked worktrees still point to where
/// it was, so it mends them straight away, since there's nothing to choose.
@MainActor
func locateRepository(_ repository: ListedRepository, list: RepositoryList, select: @escaping (WorktreeSelection) -> Void) {
    guard let folder = chooseRepositoryFolder(message: "Where is \(repository.name) now?", near: repository.folder) else { return }
    Task {
        let selection: WorktreeSelection
        do {
            selection = try await list.locate(repository, at: folder)
        } catch {
            showAlert("Can't open this folder", error)
            return
        }
        select(selection)
        guard let located = list.repository(at: selection.repository) else { return }
        do {
            try await list.repairWorktrees(of: located)
        } catch {
            showAlert("Can't repair the worktrees of \(located.name)", error)
        }
    }
}

/// Shows a dialog from outside of any view, on the window in front. These come from
/// the open panel, which isn't part of a view that could present one.
@MainActor
func showAlert(_ title: String, _ error: any Error) {
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.dialogMessage
        alert.runModal()
        return
    }
    let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    sheet.titlebarAppearsTransparent = true
    sheet.titleVisibility = .hidden
    let content = DialogContent.refusal(
        id: title,
        title: title,
        command: error.gitArguments,
        said: error.dialogMessage
    ) { [weak window, weak sheet] in
        if let window, let sheet { window.endSheet(sheet) }
    }
    let host = NSHostingController(rootView: DialogSheet(content: content))
    sheet.contentViewController = host
    sheet.setContentSize(host.view.fittingSize)
    window.beginSheet(sheet)
}

extension FocusedValues {
    /// The worktree the focused window shows, so that a repository opened
    /// from the menu shows in that window.
    @Entry var selection: Binding<WorktreeSelection?>?
    /// What the focused window's rail has selected, for the View menu.
    @Entry var sidebarScope: Binding<SidebarScope>?
    /// Whether the focused window shows its rail, for the View menu.
    @Entry var showsOrganizationRail: Binding<Bool>?
}
