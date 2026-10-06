import CoreServices
import Foundation

public enum FileChange: Sendable, Equatable {
    case created
    /// Written in place, or replaced by a rename.
    case modified
    case deleted
}

public enum FileWatcherError: Error, Equatable, Sendable {
    case directoryMissing(path: String)
    case streamFailed(path: String)
}

/// Watches one file through FSEvents on its folder. Raw events are debounced,
/// then the file's identity, size and modification time are compared with the
/// last seen state, so an in-place write, a rename-over, a delete or a create
/// each produce one `FileChange`, and events that change nothing produce none.
public final class FileWatcher: Sendable {
    public let changes: AsyncStream<FileChange>
    private let monitor: Monitor

    public init(url: URL, debounce: Duration = .milliseconds(200)) throws(FileWatcherError) {
        let folder = url.deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
            let canonicalFolder = Self.canonicalPath(folder)
        else { throw .directoryMissing(path: folder) }
        let path = URL(fileURLWithPath: canonicalFolder).appendingPathComponent(url.lastPathComponent).path
        let target = Self.canonicalPath(path) ?? path
        let (stream, continuation) = AsyncStream.makeStream(of: FileChange.self)
        changes = stream
        monitor = Monitor(paths: Set([path, target]), statPath: path, debounce: debounce, continuation: continuation)
        continuation.onTermination = { [weak monitor] _ in monitor?.stop() }
        guard monitor.start() else { throw .streamFailed(path: folder) }
    }

    /// `realpath`, because FSEvents reports `/private/var/...` where
    /// `URL.resolvingSymlinksInPath()` strips the `/private` prefix.
    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func stop() {
        monitor.stop()
    }

    deinit {
        monitor.stop()
    }
}

private struct FileState: Equatable {
    var exists = false
    var device: dev_t = 0
    var inode: ino_t = 0
    var size: off_t = 0
    var modifiedSeconds = 0
    var modifiedNanoseconds = 0

    init(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return }
        exists = true
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
}

/// Mutable state is only touched on `queue`, which is also the FSEvents queue.
private final class Monitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Pitot.FileWatcher")
    private let paths: Set<String>
    private let statPath: String
    private let debounce: DispatchTimeInterval
    private let continuation: AsyncStream<FileChange>.Continuation
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var lastState: FileState
    private var stopped = false

    init(paths: Set<String>, statPath: String, debounce: Duration, continuation: AsyncStream<FileChange>.Continuation) {
        self.paths = paths
        self.statPath = statPath
        let (seconds, attoseconds) = debounce.components
        self.debounce = .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
        self.continuation = continuation
        lastState = FileState(path: statPath)
    }

    func start() -> Bool {
        queue.sync {
            let folders = Set(paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            )
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let monitor = Unmanaged<Monitor>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                monitor.receive(paths: paths, flags: Array(UnsafeBufferPointer(start: eventFlags, count: count)))
            }
            guard
                let created = FSEventStreamCreate(
                    kCFAllocatorDefault,
                    callback,
                    &context,
                    Array(folders) as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                    0.05,
                    flags
                )
            else { return false }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            stream = created
            return true
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            pending?.cancel()
            pending = nil
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
            continuation.finish()
        }
    }

    private func receive(paths eventPaths: [String], flags: [FSEventStreamEventFlags]) {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        let relevant = zip(eventPaths, flags).contains { path, flag in
            paths.contains(path) || flag & rescan != 0
        }
        guard relevant, !stopped else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.emitIfChanged() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func emitIfChanged() {
        pending = nil
        guard !stopped else { return }
        let state = FileState(path: statPath)
        let previous = lastState
        lastState = state
        switch (previous.exists, state.exists) {
        case (false, true): continuation.yield(.created)
        case (true, false): continuation.yield(.deleted)
        case (true, true) where state != previous: continuation.yield(.modified)
        default: break
        }
    }
}
