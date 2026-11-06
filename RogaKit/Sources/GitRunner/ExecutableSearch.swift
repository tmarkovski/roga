import Darwin
import Foundation

/// Finding a program the way Roga finds git: through the folders of a `PATH`
/// and then a few places where installers put it, without asking a shell.
///
/// Apps started from Finder or the Dock don't get the user's `PATH`, so Roga
/// reads it from the login shell (decision 3) and looks through it itself. The
/// same walk finds git and the agents' command-line tools (decision 41).
public enum ExecutableSearch {
    /// Every program called one of `names` in the folders of `searchPath`, in
    /// order, and then each of the `wellKnown` paths, as long as it's an
    /// executable regular file.
    ///
    /// Only absolute paths count, because a relative folder in `PATH` would be
    /// relative to wherever Roga happens to run. When two paths lead to the same
    /// file, as a symbolic link does, only the first one is kept, so no program
    /// is run or reported twice. The paths come back as they were found, not as
    /// their real paths, since that's how people know them.
    ///
    /// - Parameters:
    ///   - names: The program's names. In each folder they're tried in this
    ///     order.
    ///   - searchPath: Folders separated by colons, as in `PATH`.
    ///   - wellKnown: Full paths of the program, tried after the search path.
    public static func candidates(named names: [String], searchPath: String, wellKnown: [String]) -> [String] {
        let folders = searchPath.split(separator: ":").map(String.init)
        let inPath = folders.filter { $0.hasPrefix("/") }.flatMap { folder in
            names.map { (folder as NSString).appendingPathComponent($0) }
        }
        var seen: Set<String> = []
        var found: [String] = []
        for candidate in inPath + wellKnown where candidate.hasPrefix("/") {
            guard isExecutableFile(candidate) else { continue }
            guard seen.insert(realPath(candidate)).inserted else { continue }
            found.append(candidate)
        }
        return found
    }

    /// Whether `path` is a regular file this process may run. A folder can
    /// have its execute bit set too, so the type is checked first.
    public static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    /// The path with every symbolic link, `.` and `..` resolved, or the path as
    /// it is when it doesn't exist.
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
