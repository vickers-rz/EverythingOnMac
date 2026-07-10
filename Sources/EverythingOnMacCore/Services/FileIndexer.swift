import Foundation

public struct IndexerConfiguration: Sendable {
    public var roots: [URL]
    public var excludedPaths: [String]

    public init(roots: [URL], excludedPaths: [String] = []) {
        self.roots = roots
        self.excludedPaths = excludedPaths
    }
}

public actor FileIndexer {
    private var files: [String: FileMetadata] = [:]
    private let configuration: IndexerConfiguration

    public init(configuration: IndexerConfiguration) {
        self.configuration = configuration
    }

    public func rebuild() async {
        var updated: [String: FileMetadata] = [:]

        for root in configuration.roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .typeIdentifierKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                if shouldExclude(fileURL.path) {
                    enumerator.skipDescendants()
                    continue
                }

                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .typeIdentifierKey]),
                      values.isRegularFile == true
                else {
                    continue
                }

                if let metadata = metadata(for: fileURL, resourceValues: values) {
                    updated[fileURL.path] = metadata
                }
            }
        }

        files = updated
    }

    public func query(_ query: SearchQuery) async -> [SearchResult] {
        files.values.compactMap { metadata in
            guard matches(metadata, query: query) else {
                return nil
            }
            return SearchResult(metadata: metadata, source: [.filenameIndex])
        }
        .sorted { $0.metadata.path < $1.metadata.path }
    }

    public func itemCount() async -> Int {
        files.count
    }

    public func upsert(path: String) async {
        guard !shouldExclude(path), let metadata = metadata(for: URL(fileURLWithPath: path)) else {
            files.removeValue(forKey: path)
            return
        }
        files[path] = metadata
    }

    public func remove(path: String) async {
        files.removeValue(forKey: path)
    }

    private func shouldExclude(_ path: String) -> Bool {
        configuration.excludedPaths.contains { path.hasPrefix($0) }
    }

    private func metadata(for fileURL: URL, resourceValues values: URLResourceValues? = nil) -> FileMetadata? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .typeIdentifierKey]
        let resolvedValues = values ?? (try? fileURL.resourceValues(forKeys: keys))
        guard resolvedValues?.isRegularFile == true else { return nil }

        return FileMetadata(
            path: fileURL.path,
            filename: fileURL.lastPathComponent,
            fileExtension: fileURL.pathExtension.lowercased(),
            size: Int64(resolvedValues?.fileSize ?? 0),
            modificationDate: resolvedValues?.contentModificationDate,
            fileID: normalizeFileID(resolvedValues?.fileResourceIdentifier),
            uti: resolvedValues?.typeIdentifier
        )
    }

    private func matches(_ metadata: FileMetadata, query: SearchQuery) -> Bool {
        if let pathPrefix = query.pathPrefix, !metadata.path.contains(pathPrefix) {
            return false
        }

        if !query.fileExtensions.isEmpty,
           !query.fileExtensions.contains(metadata.fileExtension.lowercased()) {
            return false
        }

        for excluded in query.excludedTerms where localizedContains(metadata.filename, excluded, caseSensitive: query.isCaseSensitive) {
            return false
        }

        if query.terms.isEmpty {
            return true
        }

        return query.terms.allSatisfy { term in
            localizedContains(metadata.filename, term, caseSensitive: query.isCaseSensitive)
            || localizedContains(metadata.path, term, caseSensitive: query.isCaseSensitive)
        }
    }

    private func localizedContains(_ source: String, _ term: String, caseSensitive: Bool) -> Bool {
        if caseSensitive {
            return source.contains(term)
        }
        return source.localizedCaseInsensitiveContains(term)
    }

    private func normalizeFileID(_ identifier: Any?) -> UInt64? {
        switch identifier {
        case let number as NSNumber:
            return number.uint64Value
        case let data as Data:
            return data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return nil }
                let byteCount = min(rawBuffer.count, MemoryLayout<UInt64>.size)
                var value: UInt64 = 0
                withUnsafeMutableBytes(of: &value) { destination in
                    destination.copyBytes(from: UnsafeRawBufferPointer(start: baseAddress, count: byteCount))
                }
                return value
            }
        default:
            return nil
        }
    }
}
