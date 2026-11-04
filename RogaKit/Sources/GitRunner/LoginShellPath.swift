import Darwin
import Foundation
import Synchronization

/// Reads the `PATH` that the user's login shell sets up.
///
/// Apps started from Finder or the Dock get a minimal `PATH` that doesn't
/// include Homebrew or anything the user added, so Roga asks the shell, the
/// same way a terminal would start it (decision 3). The shell runs as a login,
/// interactive shell, because many people set `PATH` in files that only those
/// read, such as `.zshrc`. Interactive shells can print anything, so the path
/// is printed between markers.
public enum LoginShellPath {
    static let startMarker = "_ROGA_PATH_START_"
    static let endMarker = "_ROGA_PATH_END_"

    /// The user's login shell, from their account, then `SHELL`, then zsh.
    public static var userShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Returns the shell's `PATH`, or nil if the shell couldn't be started,
    /// didn't print it, or took longer than `timeout`.
    public static func read(shell: String = userShell, timeout: Duration = .seconds(5)) async -> String? {
        let command = "printf '%s%s%s' \(startMarker) \"$PATH\" \(endMarker)"
        guard let process = try? ChildProcess.spawn(
            executable: shell,
            arguments: ["-i", "-l", "-c", command],
            environment: ProcessInfo.processInfo.environment
        ) else { return nil }

        // Stop the shell if it hasn't finished in time. A shell that has
        // already printed the path is left to finish on its own until then.
        let timer = Task {
            try await Task.sleep(for: timeout)
            process.terminate(grace: .milliseconds(500))
            process.output.close()
        }

        var output: [UInt8] = []
        while let chunk = try? await process.output.next() {
            output.append(contentsOf: chunk)
            if let path = path(in: output) {
                // Something the shell started in the background may hold its
                // output open, so stop reading as soon as the path is there.
                process.output.close()
                if process.currentStatus != nil { timer.cancel() }
                return path
            }
            if output.count > 1 << 20 { break }
        }
        timer.cancel()
        process.terminate(grace: .milliseconds(500))
        process.output.close()
        return nil
    }

    static func path(in output: [UInt8]) -> String? {
        let text = String(decoding: output, as: UTF8.self)
        guard let start = text.range(of: startMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
        else { return nil }
        let path = String(text[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }
}
