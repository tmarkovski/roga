import CoreServices
import Foundation
import Synchronization

/// One path that FSEvents says changed, with what it says happened to it.
struct FolderEvent: Sendable, Hashable {
    var path: String
    var flags: FSEventStreamEventFlags

    /// Whether the path is a folder rather than a file.
    var isFolder: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 }

    /// Whether FSEvents lost track of what changed under the path, so that
    /// anything there may have changed.
    var mustScan: Bool {
        flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        ) != 0
    }

    /// Whether only the path's extended attributes or Finder information
    /// changed, as when Spotlight, Finder or a sync app tags a file. git never
    /// looks at those.
    var onlyAttributes: Bool {
        let attributes = FSEventStreamEventFlags(kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemFinderInfoMod)
        let contents = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
                | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemChangeOwner
        )
        return flags & attributes != 0 && flags & contents == 0 && !mustScan
    }
}

/// An FSEvents stream over some folders and everything in them. It reports the
/// files that changed, in batches that start about `latency` seconds after the
/// first change in each, so that what a git command writes arrives together.
///
/// The handler runs on a queue of the watcher's own, one batch at a time.
final class FolderWatcher: Sendable {
    typealias Handler = @Sendable ([FolderEvent]) -> Void

    let folders: [String]
    private let queue: DispatchQueue
    private nonisolated(unsafe) let stream: FSEventStreamRef

    /// The handler, kept alive by the stream until it's released.
    private final class Box: Sendable {
        let handler: Handler
        init(_ handler: @escaping Handler) { self.handler = handler }
    }

    /// Starts watching, or returns nil when FSEvents can't, as on a volume that
    /// doesn't record changes.
    ///
    /// - Parameter excluding: Folders inside `folders` whose changes nobody
    ///   needs, such as git's objects, so that they don't wake the watcher. At
    ///   most eight, which is all FSEvents takes.
    init?(folders: [String], excluding: [String] = [], latency: TimeInterval = 0.1, handler: @escaping Handler) {
        guard !folders.isEmpty else { return nil }
        self.folders = folders
        queue = DispatchQueue(label: "sh.roga.folder-watcher", qos: .utility)
        let box = Unmanaged.passRetained(Box(handler))
        var context = FSEventStreamContext(
            version: 0,
            info: box.toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var events: [FolderEvent] = []
            events.reserveCapacity(count)
            for index in 0..<count {
                guard let path = paths[index] as? String else { continue }
                events.append(FolderEvent(path: path, flags: flags[index]))
            }
            box.handler(events)
        }
        let options = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            folders as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            options
        ) else {
            box.release()
            return nil
        }
        self.stream = stream
        if !excluding.isEmpty {
            FSEventStreamSetExclusionPaths(stream, Array(excluding.prefix(8)) as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
    }

    /// Stops the stream. A batch that's being handled finishes, and none come
    /// after it.
    func stop() {
        guard !stopped.exchange(true, ordering: .relaxed) else { return }
        // On the stream's own queue, so that it can't be released while it's
        // calling the handler. Only that queue touches it from here on.
        nonisolated(unsafe) let stream = stream
        queue.async {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private let stopped = Atomic(false)

    deinit {
        stop()
    }
}
