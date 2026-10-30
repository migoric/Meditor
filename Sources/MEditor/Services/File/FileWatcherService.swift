import CoreServices
import Foundation

// MARK: - C callback (must be a non-capturing function pointer)

private let fileWatcherCallback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
    guard let info else { return }
    let watcher = Unmanaged<FileWatcherService>.fromOpaque(info).takeUnretainedValue()
    // Read the handler under the lock to avoid racing with stopWatching.
    let handler = watcher.lockedGetHandler()
    if let handler {
        let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        let urls = (0..<eventCount).compactMap { index -> URL? in
            guard let path = paths[index] else { return nil }
            return URL(fileURLWithPath: String(cString: path))
        }
        DispatchQueue.main.async { handler(urls) }
    }
}

final class FileWatcherService: FileWatcherServiceProtocol {
    private var streamRef: FSEventStreamRef?
    /// 与 stream context 的 `passRetained` 配对，stopWatching 里对称 release。
    /// 流存活期间回调随时可能触发，retain 保证 deinit 与回调竞态窗口内 self 不悬垂。
    private var retainedSelf: Unmanaged<FileWatcherService>?
    private let queue = DispatchQueue(label: "com.meditor.filewatcher")
    /// Protected by `lock` — accessed from both `queue` (callback) and main thread.
    private var _onChange: (@Sendable ([URL]) -> Void)?
    private let lock = NSLock()

    /// Thread-safe read of the onChange handler.
    fileprivate func lockedGetHandler() -> (@Sendable ([URL]) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return _onChange
    }

    func startWatching(urls: [URL], onChange: @escaping @Sendable ([URL]) -> Void) {
        stopWatching()

        lock.lock()
        _onChange = onChange
        lock.unlock()

        let paths = urls.map { $0.path } as CFArray

        // passRetained：在 stopWatching（deinit 亦走此路径）中对称 release，
        // 覆盖 deinit 与回调的竞态窗口。若流创建失败，立即归还这次 retain。
        let retained = Unmanaged.passRetained(self)
        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fileWatcherCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents)
        ) else {
            retained.release()
            return
        }

        streamRef = stream
        retainedSelf = retained
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stopWatching() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil

        // Drain any in-flight callbacks on the queue before clearing the handler.
        // After FSEventStreamInvalidate, no NEW callbacks will fire, but already-
        // dispatched blocks may still be in the queue. This sync barrier ensures
        // they complete before we nil out the handler.
        queue.sync {}

        // 与 startWatching 的 passRetained 对称释放。此时队列已排空，
        // 不会再有回调经 takeUnretainedValue 访问该指针，无悬垂/双释放。
        retainedSelf?.release()
        retainedSelf = nil

        lock.lock()
        _onChange = nil
        lock.unlock()
    }

    deinit {
        stopWatching()
    }
}
