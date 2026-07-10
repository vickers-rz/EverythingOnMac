import Foundation

public struct FileSystemChange: Sendable, Equatable {
    public var path: String
    public var isRemoval: Bool

    public init(path: String, isRemoval: Bool) {
        self.path = path
        self.isRemoval = isRemoval
    }
}

public enum FileSystemEventMonitorError: Error, Sendable, LocalizedError {
    case streamCreationFailed
    case streamStartFailed

    public var errorDescription: String? {
        switch self {
        case .streamCreationFailed:
            return "无法创建文件系统事件监控流。"
        case .streamStartFailed:
            return "无法启动文件系统事件监控流。"
        }
    }
}

#if os(macOS)
import CoreServices

private final class FileSystemEventCallbackContext: @unchecked Sendable {
    let onChange: @Sendable ([FileSystemChange], FSEventStreamEventId) -> Void

    init(onChange: @escaping @Sendable ([FileSystemChange], FSEventStreamEventId) -> Void) {
        self.onChange = onChange
    }
}

public final class FileSystemEventMonitor: @unchecked Sendable {
    private let roots: [URL]
    private let latency: CFTimeInterval
    private let onChange: @Sendable ([FileSystemChange], FSEventStreamEventId) -> Void

    private let queue = DispatchQueue(label: "com.everythingonmac.fsevents", qos: .default)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let stateLock = NSLock()
    private var stream: FSEventStreamRef?
    private var callbackContext: FileSystemEventCallbackContext?

    public init(
        roots: [URL],
        latency: CFTimeInterval = 1.0,
        onChange: @escaping @Sendable ([FileSystemChange], FSEventStreamEventId) -> Void
    ) {
        self.roots = roots
        self.latency = latency
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    public func start(
        sinceEventId: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard stream == nil, !roots.isEmpty else { return }

        let contextObject = FileSystemEventCallbackContext(onChange: onChange)
        let callback: FSEventStreamCallback = { _, info, count, pathsPointer, flagsPointer, eventIdsPointer in
            guard let info else { return }
            let context = Unmanaged<FileSystemEventCallbackContext>
                .fromOpaque(info)
                .takeUnretainedValue()
            let paths = unsafeBitCast(pathsPointer, to: NSArray.self) as? [String] ?? []
            let flags = UnsafeBufferPointer(start: flagsPointer, count: count)
            let eventIds = UnsafeBufferPointer(start: eventIdsPointer, count: count)

            let safeCount = min(paths.count, count)
            let changes = (0..<safeCount).map { index in
                let flagsForPath = flags[index]
                return FileSystemChange(
                    path: paths[index],
                    isRemoval: (flagsForPath & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
                )
            }

            let maxEventId = eventIds.max() ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
            context.onChange(changes, maxEventId)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(contextObject).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            roots.map(\.path) as CFArray,
            sinceEventId,
            latency,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            throw FileSystemEventMonitorError.streamCreationFailed
        }

        callbackContext = contextObject
        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, queue)

        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            stream = nil
            callbackContext = nil
            throw FileSystemEventMonitorError.streamStartFailed
        }
    }

    public func stop() {
        stateLock.lock()
        guard let activeStream = stream else {
            stateLock.unlock()
            return
        }
        let retainedContext = callbackContext
        stream = nil
        callbackContext = nil
        stateLock.unlock()

        FSEventStreamStop(activeStream)
        FSEventStreamInvalidate(activeStream)
        FSEventStreamRelease(activeStream)

        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
        withExtendedLifetime(retainedContext) {}
    }
}
#else
public final class FileSystemEventMonitor: @unchecked Sendable {
    public init(
        roots: [URL],
        latency: TimeInterval = 1.0,
        onChange: @escaping @Sendable ([FileSystemChange], UInt64) -> Void
    ) {}

    public func start(sinceEventId: UInt64 = 0) throws {}
    public func stop() {}
}
#endif
