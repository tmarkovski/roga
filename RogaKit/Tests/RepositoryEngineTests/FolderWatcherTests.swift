import Darwin
import Foundation
import Testing
@testable import RepositoryEngine

/// The stream over folders, when FSEvents can't make one.
struct FolderWatcherTests {
    /// FSEvents opens the folders on the way down to the ones it watches, and
    /// can't make a stream when the process has no file descriptors left, as
    /// Roga didn't once enough repositories were in the sidebar. The watcher
    /// crashed then.
    ///
    /// It runs in a process of its own, because it uses up every descriptor
    /// that process may have, and because what went wrong was a crash.
    @Test func givesUpWhenThereAreNoFileDescriptorsLeft() async {
        await #expect(processExitsWith: .success) {
            var limit = rlimit()
            getrlimit(RLIMIT_NOFILE, &limit)
            limit.rlim_cur = 128
            setrlimit(RLIMIT_NOFILE, &limit)
            var held: [Int32] = []
            while true {
                let descriptor = open("/dev/null", O_RDONLY)
                if descriptor < 0 { break }
                held.append(descriptor)
            }
            let watcher = FolderWatcher(folders: [NSTemporaryDirectory()]) { _ in }
            held.forEach { close($0) }
            // A watcher would mean FSEvents no longer needs a descriptor, and
            // that this no longer tests anything.
            guard watcher == nil else { exit(EXIT_FAILURE) }
        }
    }
}
