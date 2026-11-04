import Foundation
import GitCore
import Observation

/// How the panels lay out the files that changed.
enum FileLayout: String, CaseIterable {
    /// One row for each file, with its folder in gray beside its name.
    case list
    /// The files under their folders, which open and close.
    case tree

    var title: String {
        switch self {
        case .list: "As List"
        case .tree: "As Tree"
        }
    }
}

/// The names of the settings that the panels and the menu bar share.
enum FileListSettings {
    static let layout = "fileListLayout"
}

/// One row of a list of changed files.
struct FileRow: Identifiable {
    enum Content {
        case file(DiffFile)
        /// A folder, and how many lines change under it. `title` also names any
        /// folders that have nothing else in them, as in `web/src`.
        case folder(path: String, title: String, isCollapsed: Bool, lines: DiffFile.LineCounts)
    }

    /// A row's place in a panel, since a file can be in two groups, and a
    /// commit can replace a file with a folder of the same name.
    struct ID: Hashable {
        var group: WorktreeChanges.Group?
        var path: String
        var isFolder = false
    }

    let content: Content
    /// How many folders it's under.
    var depth = 0
    /// The group of a worktree's changes it's in, or nil for a commit's file.
    let group: WorktreeChanges.Group?

    var id: ID {
        switch content {
        case .file(let file): ID(group: group, path: file.path)
        case .folder(let path, _, _, _): ID(group: group, path: path, isFolder: true)
        }
    }

    var file: DiffFile? {
        if case .file(let file) = content { file } else { nil }
    }

    /// Whether this row stands for a file: it's the file's own row, or the row
    /// of a closed folder that hides it.
    fileprivate func stands(for path: String, in group: WorktreeChanges.Group?) -> Bool {
        guard self.group == group else { return false }
        switch content {
        case .file(let file): return file.path == path
        case .folder(let folder, _, let isCollapsed, _): return isCollapsed && path.hasPrefix(folder + "/")
        }
    }
}

extension [FileRow] {
    /// The first row that's a file.
    var firstFile: FileRow? {
        first { $0.file != nil }
    }

    /// The row of the file `step` files from the one at `path`, going past the
    /// rows of folders. A file in a closed folder counts from the folder's row.
    /// A file with no row, such as one that the filter left out, goes to the
    /// first file. It's nil past either end.
    func file(_ step: Int, from path: String?, in group: WorktreeChanges.Group?) -> FileRow? {
        guard let path, var index = firstIndex(where: { $0.stands(for: path, in: group) }) else { return firstFile }
        for _ in 0..<abs(step) {
            repeat {
                index += step.signum()
                guard indices.contains(index) else { return nil }
            } while self[index].file == nil
        }
        return self[index]
    }
}

/// What the panels list of the files that changed: in which layout, what the
/// filter leaves, and which folders are closed. The commit panel and the panel
/// for uncommitted changes share it, because one takes the other's place.
@Observable
final class FileListModel {
    /// The setting, which the window passes on.
    var layout = FileLayout.list
    /// The text that narrows the files, by their paths.
    var filter = ""
    /// Whether the filter field shows, which it doesn't until someone asks for it.
    private(set) var isFilterShown = false
    /// Whether a menu command asked for the keyboard to go to the filter, which
    /// the panel does once it's showing.
    var wantsFilterFocus = false
    /// The closed folders, by their paths, of a commit's files and of each group
    /// of a worktree's. They last as long as the worktree's model, and carry
    /// over from one commit to the next.
    private var collapsedFolders: [WorktreeChanges.Group?: Set<String>] = [:]

    /// The latest rows of each list, because a large merge's would otherwise
    /// be worked out again on every step through its files.
    @ObservationIgnored private var latest: [WorktreeChanges.Group?: Latest] = [:]

    private struct Latest {
        let files: [DiffFile]
        let layout: FileLayout
        let filter: String
        let collapsed: Set<String>
        let rows: [FileRow]
    }

    /// Whether rows say which folder their files are in, because no folder's
    /// row does.
    var rowsShowFolders: Bool {
        layout == .list || !filter.isEmpty
    }

    /// Shows the filter field, or goes back to it if it's showing.
    func showFilter() {
        isFilterShown = true
        wantsFilterFocus = true
    }

    /// Hides the filter field, and lists everything again.
    func closeFilter() {
        filter = ""
        isFilterShown = false
    }

    func toggleFolder(_ path: String, in group: WorktreeChanges.Group? = nil) {
        if collapsedFolders[group, default: []].insert(path).inserted { return }
        collapsedFolders[group]?.remove(path)
    }

    /// Opens the folders that a file is in.
    func reveal(_ path: String, in group: WorktreeChanges.Group? = nil) {
        collapsedFolders[group] = collapsedFolders[group]?.filter { !path.hasPrefix($0 + "/") }
    }

    /// The rows that show of some files. A filter leaves one row for each file
    /// that matches, in either layout, because folders would take up the room
    /// that the matches need and could hide them.
    func rows(of files: [DiffFile], in group: WorktreeChanges.Group? = nil) -> [FileRow] {
        let collapsed = collapsedFolders[group] ?? []
        if let latest = latest[group], latest.files == files, latest.layout == layout, latest.filter == filter, latest.collapsed == collapsed {
            return latest.rows
        }
        let rows: [FileRow]
        if !filter.isEmpty {
            rows = files.filter(matchesFilter).map { FileRow(content: .file($0), group: group) }
        } else if layout == .tree {
            rows = FileTreeFolder(files).rows(in: group, collapsed: collapsed)
        } else {
            rows = files.map { FileRow(content: .file($0), group: group) }
        }
        latest[group] = Latest(files: files, layout: layout, filter: filter, collapsed: collapsed, rows: rows)
        return rows
    }

    /// The files that the filter leaves.
    func matching(_ files: [DiffFile], in group: WorktreeChanges.Group? = nil) -> [DiffFile] {
        filter.isEmpty ? files : rows(of: files, in: group).compactMap(\.file)
    }

    /// Whether a file's path has the filter's text in it, ignoring case, or the
    /// path it came from, which its row says too.
    private func matchesFilter(_ file: DiffFile) -> Bool {
        [file.path, file.oldPath].contains { $0?.range(of: filter, options: .caseInsensitive) != nil }
    }
}

/// A folder of a tree of files, with what's in it and how many lines change
/// under it.
private final class FileTreeFolder {
    private var folders: [String: FileTreeFolder] = [:]
    private var files: [DiffFile] = []
    private var lines = DiffFile.LineCounts(added: 0, removed: 0)

    private init() {}

    /// The top of the tree that some files make up.
    convenience init(_ files: [DiffFile]) {
        self.init()
        for file in files {
            var folder = self
            for name in file.folder.split(separator: "/") {
                folder = folder.folder(named: String(name))
                folder.lines.added += file.lines?.added ?? 0
                folder.lines.removed += file.lines?.removed ?? 0
            }
            folder.files.append(file)
        }
    }

    private func folder(named name: String) -> FileTreeFolder {
        if let folder = folders[name] { return folder }
        let folder = FileTreeFolder()
        folders[name] = folder
        return folder
    }

    /// The rows of everything under this folder that isn't in a closed folder.
    func rows(in group: WorktreeChanges.Group?, collapsed: Set<String>) -> [FileRow] {
        var rows: [FileRow] = []
        append(to: &rows, path: "", depth: 0, group: group, collapsed: collapsed)
        return rows
    }

    /// Adds its folders and then its files, each from A to Z.
    private func append(to rows: inout [FileRow], path: String, depth: Int, group: WorktreeChanges.Group?, collapsed: Set<String>) {
        for (name, first) in folders.sorted(by: { comesFirst($0.key, $1.key) }) {
            // A folder with nothing in it but another folder shares its row.
            var folder = first
            var title = name
            while folder.files.isEmpty, folder.folders.count == 1, let only = folder.folders.first {
                title += "/" + only.key
                folder = only.value
            }
            let folderPath = path + title
            let isCollapsed = collapsed.contains(folderPath)
            rows.append(FileRow(
                content: .folder(path: folderPath, title: title, isCollapsed: isCollapsed, lines: folder.lines),
                depth: depth,
                group: group
            ))
            if !isCollapsed {
                folder.append(to: &rows, path: folderPath + "/", depth: depth + 1, group: group, collapsed: collapsed)
            }
        }
        for file in files.sorted(by: { comesFirst($0.name, $1.name) }) {
            rows.append(FileRow(content: .file(file), depth: depth, group: group))
        }
    }
}

/// Names go from A to Z ignoring case, and numbers in them count as numbers.
private func comesFirst(_ first: some StringProtocol, _ second: some StringProtocol) -> Bool {
    switch first.compare(second, options: [.numeric, .caseInsensitive]) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: first < second
    }
}
