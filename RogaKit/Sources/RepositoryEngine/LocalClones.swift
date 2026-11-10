import Foundation

/// A repository found in a folder on this Mac.
public struct LocalClone: Sendable, Hashable, Identifiable {
    /// The clone's top folder, with symbolic links resolved, as git gives it.
    public var path: String
    /// When its index last changed, which is about when someone last worked
    /// in it.
    public var lastUsed: Date?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, lastUsed: Date? = nil) {
        self.path = path
        self.lastUsed = lastUsed
    }
}

/// Finds the repositories that could be added to the sidebar, without opening
/// them or running git (decision 16).
public enum LocalClones {
    /// Looks for clones in each folder and in the folders right inside it,
    /// but no deeper, and lists the latest used first. It only reads the
    /// folders and a file's date in each clone, so it's quick even where a
    /// folder holds hundreds of clones, but it still runs off the main actor
    /// in case a disk is slow.
    ///
    /// A linked worktree's `.git` is a file, so only a repository's main
    /// worktree counts. A bare repository doesn't, because it can't be told
    /// from any other folder without running git in every one of them.
    @concurrent
    public static func find(in folders: [String]) async -> [LocalClone] {
        var seen: Set<String> = []
        return folders.flatMap(candidates(in:))
            .filter { seen.insert($0).inserted }
            .map { LocalClone(path: $0, lastUsed: lastUsed($0)) }
            .sorted { first, second in
                if first.lastUsed != second.lastUsed { return (first.lastUsed ?? .distantPast) > (second.lastUsed ?? .distantPast) }
                return first.path < second.path
            }
    }

    private static func candidates(in folder: String) -> [String] {
        guard let resolved = realpath(folder, nil) else { return [] }
        defer { free(resolved) }
        let folder = String(cString: resolved)
        let children = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return ([folder] + children.sorted().map { folder + "/" + $0 }).filter(isClone)
    }

    private static func isClone(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func lastUsed(_ path: String) -> Date? {
        for file in ["index", "HEAD"] {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path + "/.git/" + file),
               let date = attributes[.modificationDate] as? Date
            {
                return date
            }
        }
        return nil
    }
}
