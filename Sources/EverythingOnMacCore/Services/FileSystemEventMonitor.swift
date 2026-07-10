import Foundation

public struct FileSystemChange: Sendable, Equatable {
    public var path: String
    public var isRemoval: Bool

    public init(path: String, isRemoval: Bool) {
        self.path = path
        self.isRemoval = isRemoval
    }
}

#if os(macOS)
import CoreServices

public final class FileSystemEventMonitor: @unchecked Sendable {
    private let roots: [URL]
    private let latency: CFTimeInterval
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable ([FileSystemChange], FSEventStreamEventId) -> Void

    private let queue = DispatchQueue(label: "com.everythingonmac.fsevents", qos: .default)

    public init(roots: [URL], latency: CFTimeInterval = 1.0, onChange: @escaping @Sendable ([FileSystemChange], FSEventStreamEventId) -> Void) {
        self.roots = roots
        self.latency = latency
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func start(sinceEventId: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)) {
        guard stream == nil, !roots.isEmpty else { return }

        let callback: FSEventStreamCallback = { _, info, count, pathsPointer, flagsPointer, eventIdsPointer in
            guard let info else { return }
            let monitor = Unmanaged<FileSystemEventMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(pathsPointer, to: NSArray.self) as? [String] ?? []
            let flags = UnsafeBufferPointer(start: flagsPointer, count: count)
            let eventIds = UnsafeBufferPointer(start: eventIdsPointer, count: count)
            
            let changes = paths.enumerated().map { index, path in
                let flagsForPath = flags[index]
                return FileSystemChange(path: path, isRemoval: (flagsForPath & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0)
            }
            
            let maxEventId = eventIds.max() ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
            monitor.onChange(changes, maxEventId)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            roots.map(\.path) as CFArray,
            sinceEventId,
            latency,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
#else
public final class FileSystemEventMonitor: @unchecked Sendable {
    public init(roots: [URL], latency: TimeInterval = 1.0, onChange: @escaping @Sendable ([FileSystemChange], UInt64) -> Void) {}
    public func start(sinceEventId: UInt64 = 0) {}
    public func stop() {}
}
#endif
