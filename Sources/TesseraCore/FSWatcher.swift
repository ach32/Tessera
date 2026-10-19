import Foundation
#if canImport(CoreServices)
import CoreServices

/// FSEvents on a folder tree, delivered on the main queue as (directory path, must rescan subfolders).
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let onEvents: ([(String, Bool)]) -> Void

    init?(path: String, latency: Double, onEvents: @escaping ([(String, Bool)]) -> Void) {
        self.onEvents = onEvents
        var context = FSEventStreamContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            var events: [(String, Bool)] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                guard let p = list[i] as? String else { continue }
                let sub = flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                events.append((p, sub))
            }
            watcher.onEvents(events)
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
#else
final class FSWatcher {
    init?(path: String, latency: Double, onEvents: @escaping ([(String, Bool)]) -> Void) { return nil }
    func stop() {}
}
#endif
