import Darwin
import Foundation

/// Where the helper finds Roga: a Unix domain socket in Roga's folder in
/// Application Support (decision 41).
///
/// The folder is named after the bundle ID, the same way `RepositoryStore`
/// names it, so a copy of Roga with its own bundle ID, such as one for trying
/// the app without real data, hears only from hooks that its own helper runs.
/// A socket needs no port and no address in the environment, and connecting
/// to one that nobody is listening on fails at once.
public enum HookSocket {
    /// The bundle ID the helper uses when it can't find the app it's in and
    /// the environment doesn't name one.
    public static let defaultBundleIdentifier = "sh.roga.app"

    /// The longest socket path in bytes. `sockaddr_un` holds 104 bytes,
    /// including the zero that ends the path.
    static let maximumPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// The socket in a support folder.
    public static func path(supportFolder: URL) -> String {
        filePath(supportFolder.appending(path: "hooks.sock"))
    }

    /// The file a listener locks, so only one copy of Roga listens on the
    /// socket at a time.
    static func lockPath(supportFolder: URL) -> String {
        filePath(supportFolder.appending(path: "hooks.lock"))
    }

    /// Roga's folder in Application Support for a bundle ID.
    public static func supportFolder(bundleIdentifier: String) -> URL {
        URL.applicationSupportDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory)
    }

    /// The path without percent encoding or a trailing slash.
    private static func filePath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Calls `body` with the socket address of `path`, or returns nil when
    /// the path is too long to fit in one.
    static func withAddress<Result>(
        of path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) -> Result? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumPathLength, !bytes.contains(0) else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
