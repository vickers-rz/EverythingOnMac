import Foundation

public struct VolumeCapabilities: Sendable, Equatable {
    public var rootPath: String
    public var volumeName: String?
    public var localizedFormatDescription: String?
    public var supportsPersistentFileIDs: Bool
    public var supportsFastDirectorySizing: Bool
    public var supportsSearchFS: Bool
    public var isAPFS: Bool

    public init(
        rootPath: String,
        volumeName: String?,
        localizedFormatDescription: String?,
        supportsPersistentFileIDs: Bool,
        supportsFastDirectorySizing: Bool,
        supportsSearchFS: Bool,
        isAPFS: Bool
    ) {
        self.rootPath = rootPath
        self.volumeName = volumeName
        self.localizedFormatDescription = localizedFormatDescription
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
        let isAPFS = format?.localizedCaseInsensitiveContains("apfs") == true

        return VolumeCapabilities(
            rootPath: root.path,
            volumeName: values?.volumeName,
            localizedFormatDescription: format,
            supportsPersistentFileIDs: values?.volumeSupportsPersistentIDs ?? false,
            supportsFastDirectorySizing: isAPFS,
            supportsSearchFS: false,
            isAPFS: isAPFS
        )
    }
}
