import AppKit
import SwiftUI

/// Asks for a repository's folder with an open panel, and returns its path.
@MainActor
func chooseRepositoryFolder(message: String = "Choose a repository, or any folder inside one.") -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = message
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return (url.path(percentEncoded: false) as NSString).standardizingPath
}

/// Asks for a folder and adds its repository to the sidebar, then passes
/// the worktree the folder is in to `select`. It explains in an alert when
/// the folder isn't in a repository.
@MainActor
func openRepository(list: RepositoryList, select: @escaping (WorktreeSelection) -> Void) {
    guard let folder = chooseRepositoryFolder() else { return }
    Task {
        do {
            select(try await list.add(folder: folder))
        } catch {
            showAlert("Can't Open This Folder", error)
        }
    }
}

/// Asks where a repository that can't be found is now, and passes the
/// worktree to select to `select`.
@MainActor
func locateRepository(_ repository: ListedRepository, list: RepositoryList, select: @escaping (WorktreeSelection) -> Void) {
    guard let folder = chooseRepositoryFolder(message: "Where is \(repository.name) now?") else { return }
    Task {
        do {
            select(try await list.locate(repository, at: folder))
        } catch {
            showAlert("Can't Open This Folder", error)
        }
    }
}

@MainActor
func showAlert(_ title: String, _ error: any Error) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = String(describing: error)
    if let window = NSApp.keyWindow {
        alert.beginSheetModal(for: window)
    } else {
        alert.runModal()
    }
}

extension FocusedValues {
    /// The worktree the focused window shows, so that a repository opened
    /// from the menu shows in that window.
    @Entry var selection: Binding<WorktreeSelection?>?
}
