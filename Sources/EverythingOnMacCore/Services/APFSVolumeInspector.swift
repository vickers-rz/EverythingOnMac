import Foundation

#if os(macOS)
import Darwin
#endif

public struct VolumeCapabilities: Sendable, Equatable {
    public var rootPath: String
    public var volumeName: String?
    public var localizedFormatDescription: String?
    public var fileSystemType: String?
    public var supportsPersistentFileIDs: Bool
    public var supportsFastDirectorySizing: Bool
    public var supportsSearchFS: Bool
    public var isAPFS: Bool

    public init(
        rootPath: String,
        volumeName: String?,
        localizedFormatDescription: String?,
        fileSystemType: String?,
        supportsPersistentFileIDs: Bool,
        supportsFastDirectorySizing: Bool,
        supportsSearchFS: Bool,
        isAPFS: Bool
    ) {
        self.rootPath = rootPath
        self.volumeName = volumeName
        self.localizedFormatDescription = localizedFormatDescription
        self.fileSystemType = fileSystemType
        self.supportsPersistentFileIDs = supportsPersistentFileIDs
        self.supportsFastDirectorySizing = supportsFastDirectorySizing
        self.supportsSearchFS = supportsSearchFS
        self.isAPFS = isAPFS
    }
}

public enum APFSVolumeInspector {
    public static func inspect(roots: [URL]) -> [VolumeCapabilities] {
        roots.map(inspect(root:))
    }

    public static func inspect(root: URL) -> VolumeCapabilities {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeSupportsPersistentIDsKey
        ]

        let values = try? root.resourceValues(forKeys: keys)
        let format = values?.volumeLocalizedFormatDescription
        let fileSystemType = platformFileSystemType(for: root)
        let isAPFS = fileSystemType?.caseInsensitiveCompare("apfs") == .orderedSame
            || format?.localizedCaseInsensitiveContains("apfs") == true

        return VolumeCapabilities(
            rootPath: root.path,
            volumeName: values?.volumeName,
            localizedFormatDescription: format,
            fileSystemType: fileSystemType,
            supportsPersistentFileIDs: values?.volumeSupportsPersistentIDs ?? false,
            supportsFastDirectorySizing: isAPFS,
            supportsSearchFS: false,
            isAPFS: isAPFS
        )
    }

    private static func platformFileSystemType(for root: URL) -> String? {
        #if os(macOS)
        var stats = statfs()
        guard root.withUnsafeFileSystemRepresentation({ statfs($0, &stats) }) == 0 else {
            return nil
        }
        return withUnsafePointer(to: &stats.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: stats.f_fstypename)) { cString in
                String(cString: cString)
            }
        }
        #else
        return nil
        #endif
    }
}
