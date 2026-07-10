import Foundation

protocol FileIndexing {
    func indexFiles(at root: URL, fileNameQuery: String?, maxResults: Int, includeHidden: Bool) throws -> [IndexedFile]
}

struct FileIndexer: FileIndexing {
    func indexFiles(at root: URL, fileNameQuery: String?, maxResults: Int, includeHidden: Bool) throws -> [IndexedFile] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .nameKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .volumeLocalizedFormatDescriptionKey,
            .isHiddenKey,
        ]

        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return []
        }

        var files: [IndexedFile] = []
        let normalizedNameQuery = fileNameQuery?.lowercased()

        for case let fileURL as URL in enumerator {
            if files.count >= maxResults {
                break
            }

            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else {
                continue
            }

            if includeHidden == false, values.isHidden == true {
                continue
            }

            let name = values.name ?? fileURL.lastPathComponent
            if let normalizedNameQuery, name.lowercased().contains(normalizedNameQuery) == false {
                continue
            }

            let identifier = values.fileResourceIdentifier.map { String(describing: $0) }
            files.append(
                IndexedFile(
                    path: fileURL.path,
                    name: name,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate,
                    fileID: identifier,
                    volumeFormatDescription: values.volumeLocalizedFormatDescription
                )
            )
        }

        return files
    }
}
