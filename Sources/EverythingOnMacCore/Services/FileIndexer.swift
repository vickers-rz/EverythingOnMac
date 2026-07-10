import Foundation
import CSearchFS
import os

public struct IndexerConfiguration: Sendable {
    public var roots: [URL]
    public var excludedPaths: [String]
    public var databasePath: String?
    public var useFastVolumeScan: Bool

    public init(
        roots: [URL],
        excludedPaths: [String] = [],
        databasePath: String? = nil,
        useFastVolumeScan: Bool = true
    ) {
        self.roots = roots
        self.excludedPaths = excludedPaths
        self.databasePath = databasePath
        self.useFastVolumeScan = useFastVolumeScan
    }
}

private final class ScanContext {
    var objectRows: [[Any]] = []
    var entryRows: [[Any]] = []
    var seenObjects = Set<FileIdentity>()
    var writeError: Error?
    var isCancelled = false
    let volumeUUID: String
    let database: SQLiteDatabase

    init(volumeUUID: String, database: SQLiteDatabase) {
        self.volumeUUID = volumeUUID
        self.database = database
    }

    func append(
        fileID: UInt64,
        parentID: UInt64,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modificationDate: Double,
        uti: String?,
        linkCount: Int64? = nil
    ) {
        let identity = FileIdentity(volumeUUID: volumeUUID, fileID: fileID)
        if seenObjects.insert(identity).inserted {
            objectRows.append([
                volumeUUID, Int64(bitPattern: fileID), isDirectory ? 1 : 0,
                isDirectory ? "" : URL(fileURLWithPath: name).pathExtension.lowercased(),
                size, modificationDate, uti ?? NSNull(), linkCount ?? NSNull()
            ])
        }
        entryRows.append([
            volumeUUID, Int64(bitPattern: parentID), Int64(bitPattern: fileID), name,
            Int64(bitPattern: FuzzyMatcher.characterMask(for: name, caseSensitive: false))
        ])
    }

    func flush() {
        guard writeError == nil, (!objectRows.isEmpty || !entryRows.isEmpty) else { return }
        do {
            if !objectRows.isEmpty {
                try database.executeBatch(sql: FileIndexer.objectUpsertSQL, items: objectRows)
            }
            if !entryRows.isEmpty {
                try database.executeBatch(sql: FileIndexer.entryUpsertSQL, items: entryRows)
            }
            objectRows.removeAll(keepingCapacity: true)
            entryRows.removeAll(keepingCapacity: true)
            seenObjects.removeAll(keepingCapacity: true)
        } catch {
            writeError = error
        }
    }
}

public enum FileIndexSearchError: Error, Sendable, Equatable, LocalizedError {
    case invalidPathPrefix(String)
    case databaseError(String)
    case indexCorrupted(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPathPrefix(let path): return "无法解析搜索路径：\(path)"
        case .databaseError(let message): return "文件索引查询失败：\(message)"
        case .indexCorrupted(let message): return "文件索引结构损坏：\(message)"
        }
    }
}

public struct FileIndexQueryResult: Sendable, Equatable {
    public let results: [SearchResult]
    public let skippedCorruptNodeCount: Int
    public let firstCorruptionDescription: String?
    public let candidateScanLimitReached: Bool

    public init(
        results: [SearchResult],
        skippedCorruptNodeCount: Int,
        firstCorruptionDescription: String?,
        candidateScanLimitReached: Bool = false
    ) {
        self.results = results
        self.skippedCorruptNodeCount = skippedCorruptNodeCount
        self.firstCorruptionDescription = firstCorruptionDescription
        self.candidateScanLimitReached = candidateScanLimitReached
    }
}

public actor FileIndexer {
    static let objectUpsertSQL = """
        INSERT INTO fs_objects
            (volume_uuid, file_id, is_directory, file_extension, size, modification_date, uti, link_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(volume_uuid, file_id) DO UPDATE SET
            is_directory = excluded.is_directory,
            file_extension = excluded.file_extension,
            size = excluded.size,
            modification_date = excluded.modification_date,
            uti = excluded.uti,
            link_count = excluded.link_count;
        """

    static let entryUpsertSQL = """
        INSERT INTO fs_entries
            (volume_uuid, parent_file_id, target_file_id, name, name_character_mask)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(volume_uuid, parent_file_id, name) DO UPDATE SET
            target_file_id = excluded.target_file_id,
            name_character_mask = excluded.name_character_mask;
        """

    private let configuration: IndexerConfiguration
    private let database: SQLiteDatabase
    private let logger = Logger(subsystem: "com.everythingonmac", category: "FileIndexer")
    private var isCacheLoaded = false
    private var directoryCache: [String: [UInt64: (parentID: UInt64, name: String)]] = [:]
    private var volumeMountPoints: [String: String] = [:]

    public init(configuration: IndexerConfiguration) throws {
        self.configuration = configuration
        self.database = try SQLiteDatabase(path: configuration.databasePath ?? Self.defaultDatabasePath())
        for root in configuration.roots {
            let values = try? root.resourceValues(forKeys: [.volumeUUIDStringKey])
            let volumeUUID = values?.volumeUUIDString ?? root.path
            volumeMountPoints[volumeUUID] = Self.realMountPoint(for: root.path) ?? root.path
        }
    }

    private static func defaultDatabasePath() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EverythingOnMac/everything.db").path
    }

    private func ensureCacheLoaded() async throws {
        guard !isCacheLoaded else { return }
        for root in configuration.roots {
            let values = try? root.resourceValues(forKeys: [.volumeUUIDStringKey])
            cacheAncestors(of: root, volumeUUID: values?.volumeUUIDString ?? root.path)
        }
        let rows = try database.query(sql: """
            SELECT e.volume_uuid, e.target_file_id, e.parent_file_id, e.name
            FROM fs_entries e
            JOIN fs_objects o ON o.volume_uuid = e.volume_uuid AND o.file_id = e.target_file_id
            WHERE o.is_directory = 1;
            """)
        for row in rows {
            guard let volume = row["volume_uuid"] as? String,
                  let target = row["target_file_id"] as? Int64,
                  let parent = row["parent_file_id"] as? Int64,
                  let name = row["name"] as? String else { continue }
            directoryCache[volume, default: [:]][UInt64(bitPattern: target)] =
                (UInt64(bitPattern: parent), name)
        }
        isCacheLoaded = true
    }

    private func resetCache() async throws {
        directoryCache.removeAll()
        isCacheLoaded = false
        try await ensureCacheLoaded()
    }

    private func cacheAncestors(of root: URL, volumeUUID: String) {
        var current = root
        while current.path != "/" && !current.path.isEmpty {
            guard let values = try? current.resourceValues(forKeys: [.fileResourceIdentifierKey, .parentDirectoryURLKey]),
                  let fileID = normalizeFileID(values.fileResourceIdentifier) else { break }
            let parentURL = values.parentDirectory ?? current.deletingLastPathComponent()
            let parentID = (try? parentURL.resourceValues(forKeys: [.fileResourceIdentifierKey]))
                .flatMap { normalizeFileID($0.fileResourceIdentifier) } ?? 2
            directoryCache[volumeUUID, default: [:]][fileID] = (parentID, current.lastPathComponent)
            current = parentURL
        }
    }

    private func resolvePath(volumeUUID: String, parentID: UInt64, name: String) throws -> String {
        var parts = [name]
        var currentParent = parentID
        var visited = Set<UInt64>()
        var depth = 0
        while currentParent != 0 && currentParent != 2 {
            guard depth < 100 else {
                throw FileIndexSearchError.indexCorrupted("节点 \(name) 的父目录层级超过 100。")
            }
            guard visited.insert(currentParent).inserted else {
                throw FileIndexSearchError.indexCorrupted("节点 \(name) 的父目录链存在循环引用。")
            }
            guard let node = directoryCache[volumeUUID]?[currentParent] else {
                throw FileIndexSearchError.indexCorrupted("节点 \(name) 缺少父目录 \(currentParent)。")
            }
            parts.append(node.name)
            currentParent = node.parentID
            depth += 1
        }
        let relative = parts.reversed().joined(separator: "/")
        let mount = volumeMountPoints[volumeUUID] ?? ""
        let full = mount == "/" ? "/" + relative : mount + "/" + relative
        if full.hasPrefix("/System/Volumes/Data/") { return String(full.dropFirst("/System/Volumes/Data".count)) }
        return full == "/System/Volumes/Data" ? "/" : full
    }

    public func rebuild() async throws {
        try Task.checkCancellation()
        try database.execute(sql: "BEGIN IMMEDIATE;")
        do {
            try database.execute(sql: "DELETE FROM fs_entries;")
            try database.execute(sql: "DELETE FROM fs_objects;")
            try database.execute(sql: "DELETE FROM metadata WHERE key = 'last_event_id';")
            try database.execute(sql: "COMMIT;")
        } catch {
            try? database.execute(sql: "ROLLBACK;")
            throw error
        }
        directoryCache.removeAll()

        var scannedVolumes = Set<String>()
        for root in configuration.roots {
            try Task.checkCancellation()
            let values = try? root.resourceValues(forKeys: [.volumeUUIDStringKey])
            let volumeUUID = values?.volumeUUIDString ?? root.path
            guard scannedVolumes.insert(volumeUUID).inserted else { continue }
            let roots = configuration.roots.filter {
                ((try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? $0.path) == volumeUUID
            }
            guard configuration.useFastVolumeScan,
                  let mount = Self.realMountPoint(for: root.path) else {
                try scanVolumeRecursively(volumeUUID: volumeUUID, rootsOnThisVolume: roots)
                continue
            }
            let context = ScanContext(volumeUUID: volumeUUID, database: database)
            let pointer = Unmanaged.passUnretained(context).toOpaque()
            let code = scan_volume_catalog(mount, { fileID, parentID, namePtr, isDir, size, modDate, raw in
                guard let raw else { return }
                let context = Unmanaged<ScanContext>.fromOpaque(raw).takeUnretainedValue()
                if Task.isCancelled {
                    context.isCancelled = true
                    context.objectRows.removeAll()
                    context.entryRows.removeAll()
                    return
                }
                guard !context.isCancelled else { return }
                context.append(
                    fileID: fileID,
                    parentID: parentID,
                    name: namePtr.map(String.init(cString:)) ?? "",
                    isDirectory: isDir != 0,
                    size: size,
                    modificationDate: modDate,
                    uti: nil
                )
                if context.entryRows.count >= 10_000 { context.flush() }
            }, pointer)
            if context.isCancelled { throw CancellationError() }
            if code != 0 {
                try deleteVolume(volumeUUID)
                try scanVolumeRecursively(volumeUUID: volumeUUID, rootsOnThisVolume: roots)
                continue
            }
            context.flush()
            if let error = context.writeError { throw error }
            let rootIDs = roots.compactMap {
                normalizeFileID((try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier)
            }
            guard rootIDs.count == roots.count else {
                try deleteVolume(volumeUUID)
                try scanVolumeRecursively(volumeUUID: volumeUUID, rootsOnThisVolume: roots)
                continue
            }
            do {
                try pruneDatabase(volumeUUID: volumeUUID, rootIDs: rootIDs)
                try pruneExcludedPaths(volumeUUID: volumeUUID)
                try cleanupOrphanObjects(volumeUUID: volumeUUID)
            } catch {
                try deleteVolume(volumeUUID)
                try scanVolumeRecursively(volumeUUID: volumeUUID, rootsOnThisVolume: roots)
            }
        }
        try database.execute(sql: "DELETE FROM metadata WHERE key = 'rebuild_required';")
        try await resetCache()
    }

    public func query(_ query: SearchQuery) async throws -> FileIndexQueryResult {
        try await ensureCacheLoaded()
        var cte = ""
        var cteBindings: [Any] = []
        var predicates = ["1=1"]
        var bindings: [Any] = []

        if let rawPrefix = query.pathPrefix {
            let prefix = Self.canonicalUserPath(rawPrefix)
            guard FileManager.default.fileExists(atPath: prefix),
                  let values = try? URL(fileURLWithPath: prefix).resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeUUIDStringKey]),
                  let fid = normalizeFileID(values.fileResourceIdentifier),
                  let volume = values.volumeUUIDString else {
                throw FileIndexSearchError.invalidPathPrefix(rawPrefix)
            }
            cte = """
                WITH RECURSIVE path_descendants(fid) AS (
                    SELECT ?
                    UNION
                    SELECT e.target_file_id
                    FROM fs_entries e
                    JOIN fs_objects o ON o.volume_uuid = e.volume_uuid AND o.file_id = e.target_file_id
                    JOIN path_descendants p ON e.parent_file_id = p.fid
                    WHERE e.volume_uuid = ? AND o.is_directory = 1
                )
                """
            cteBindings = [Int64(bitPattern: fid), volume]
            predicates += ["e.volume_uuid = ?", "(e.parent_file_id IN (SELECT fid FROM path_descendants) OR e.target_file_id IN (SELECT fid FROM path_descendants))"]
            bindings.append(volume)
        }
        if !query.fileExtensions.isEmpty {
            let values = query.fileExtensions.map { $0.lowercased() }.sorted()
            predicates.append("o.file_extension IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
            bindings += values
        }
        for excluded in query.excludedTerms {
            predicates.append(query.isCaseSensitive ? "e.name NOT GLOB ?" : "e.name NOT LIKE ?")
            bindings.append(query.isCaseSensitive ? "*\(excluded)*" : "%\(excluded)%")
        }
        if let value = query.minSize, let op = query.minSizeOp { predicates.append("o.size \(op) ?"); bindings.append(value) }
        if let value = query.maxSize, let op = query.maxSizeOp { predicates.append("o.size \(op) ?"); bindings.append(value) }
        if let value = query.minDate, let op = query.minDateOp { predicates.append("o.modification_date \(op) ?"); bindings.append(value.timeIntervalSince1970) }
        if let value = query.maxDate, let op = query.maxDateOp { predicates.append("o.modification_date \(op) ?"); bindings.append(value.timeIntervalSince1970) }
        if let uti = query.utiFilter, !uti.isEmpty { predicates.append("o.uti LIKE ?"); bindings.append("%\(uti)%") }

        let terms = query.terms.filter { !$0.isEmpty }
        var fuzzyExpression: String?
        var fuzzyBindings: [Any] = []
        switch query.filenameMatchMode {
        case .fuzzy where !terms.isEmpty:
            let mask = terms.reduce(UInt64(0)) { $0 | FuzzyMatcher.characterMask(for: $1, caseSensitive: false) }
            predicates.append("(e.name_character_mask & ?) = ?")
            bindings += [Int64(bitPattern: mask), Int64(bitPattern: mask)]
            fuzzyExpression = terms.map { _ in "FUZZY_SCORE(?, e.name, ?)" }.joined(separator: " + ")
            for term in terms { fuzzyBindings += [term, query.isCaseSensitive] }
        case .regex:
            for term in terms { predicates.append("REGEXP_LIKE(?, e.name, ?)"); bindings += [term, query.isCaseSensitive] }
        case .literal:
            for term in terms {
                predicates.append(query.isCaseSensitive ? "e.name GLOB ?" : "e.name LIKE ?")
                bindings.append(query.isCaseSensitive ? "*\(term)*" : "%\(term)%")
            }
        case .fuzzy: break
        }

        let columns = "e.entry_id, e.volume_uuid, e.parent_file_id, e.target_file_id, e.name, o.is_directory, o.file_extension, o.size, o.modification_date, o.uti"
        let from = "FROM fs_entries e JOIN fs_objects o ON o.volume_uuid = e.volume_uuid AND o.file_id = e.target_file_id"
        let whereSQL = predicates.joined(separator: " AND ")
        var sql: String
        var allBindings = cteBindings
        if let fuzzyExpression {
            sql = "SELECT * FROM (SELECT \(columns), \(fuzzyExpression) AS fuzzy_score \(from) WHERE \(whereSQL)) WHERE fuzzy_score IS NOT NULL"
            allBindings += fuzzyBindings + bindings
        } else {
            sql = "SELECT \(columns) \(from) WHERE \(whereSQL)"
            allBindings += bindings
        }
        if let sort = query.sortOption, sort.field != .relevance && sort.field != .path {
            let field: String
            switch sort.field {
            case .filename: field = "e.name"
            case .size: field = "o.size"
            case .modificationDate: field = "o.modification_date"
            default: field = "e.name"
            }
            sql += " ORDER BY \(field) \(sort.direction == .ascending ? "ASC" : "DESC"), e.name ASC"
        } else if fuzzyExpression != nil {
            sql += " ORDER BY fuzzy_score DESC, name ASC"
        } else {
            sql += " ORDER BY e.name ASC"
        }

        let targetLimit = max(1, query.limit ?? 5_000)
        let offset = max(0, query.offset ?? 0)
        let sortByPath = query.sortOption?.field == .path
        var skipped = 0
        var firstCorruption: String?

        do {
            if sortByPath {
                let rows = try database.query(sql: cte + sql, bindings: allBindings)
                var valid = rows.compactMap { row -> SearchResult? in
                    do { return try makeResult(row: row, query: query) }
                    catch {
                        skipped += 1
                        if firstCorruption == nil { firstCorruption = error.localizedDescription }
                        return nil
                    }
                }
                let direction = query.sortOption?.direction ?? .ascending
                valid.sort { direction == .ascending ? $0.metadata.path < $1.metadata.path : $0.metadata.path > $1.metadata.path }
                return FileIndexQueryResult(
                    results: Array(valid.dropFirst(min(offset, valid.count)).prefix(targetLimit)),
                    skippedCorruptNodeCount: skipped,
                    firstCorruptionDescription: firstCorruption
                )
            }

            var databaseOffset = 0
            var validToSkip = offset
            var results: [SearchResult] = []
            let safetyLimit = 50_000
            var processed = 0
            var exhausted = false
            while results.count < targetLimit && processed < safetyLimit && !exhausted {
                try Task.checkCancellation()
                let batchSize = min(max(256, validToSkip + targetLimit - results.count), safetyLimit - processed)
                var batchBindings = allBindings
                batchBindings += [batchSize, databaseOffset]
                let rows = try database.query(sql: cte + sql + " LIMIT ? OFFSET ?", bindings: batchBindings)
                if rows.isEmpty { exhausted = true; break }
                for row in rows {
                    processed += 1
                    do {
                        let result = try makeResult(row: row, query: query)
                        if validToSkip > 0 { validToSkip -= 1 } else { results.append(result) }
                        if results.count == targetLimit { break }
                    } catch {
                        skipped += 1
                        if firstCorruption == nil { firstCorruption = error.localizedDescription }
                    }
                }
                databaseOffset += rows.count
                exhausted = rows.count < batchSize
            }
            return FileIndexQueryResult(
                results: results,
                skippedCorruptNodeCount: skipped,
                firstCorruptionDescription: firstCorruption,
                candidateScanLimitReached: results.count < targetLimit && !exhausted && processed >= safetyLimit
            )
        } catch let error as FileIndexSearchError {
            throw error
        } catch {
            throw FileIndexSearchError.databaseError(error.localizedDescription)
        }
    }

    private func makeResult(row: [String: Any], query: SearchQuery) throws -> SearchResult {
        guard let entryID = row["entry_id"] as? Int64,
              let volume = row["volume_uuid"] as? String,
              let parent = row["parent_file_id"] as? Int64,
              let target = row["target_file_id"] as? Int64,
              let name = row["name"] as? String,
              row["is_directory"] is Int64 else {
            throw FileIndexSearchError.indexCorrupted("查询结果包含缺失或类型异常的必要字段。")
        }
        let path = try resolvePath(volumeUUID: volume, parentID: UInt64(bitPattern: parent), name: name)
        if let rawPrefix = query.pathPrefix {
            let prefix = Self.canonicalUserPath(rawPrefix)
            let canonical = Self.canonicalUserPath(path)
            guard canonical == prefix || canonical.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/") else {
                throw FileIndexSearchError.indexCorrupted("路径前缀递归结果与恢复路径不一致：\(path)")
            }
        }
        guard !shouldExclude(path) else {
            throw FileIndexSearchError.indexCorrupted("查询命中了已排除路径：\(path)")
        }
        return SearchResult(metadata: FileMetadata(
            path: path,
            filename: name,
            fileExtension: row["file_extension"] as? String ?? "",
            size: row["size"] as? Int64 ?? 0,
            modificationDate: (row["modification_date"] as? Double).map(Date.init(timeIntervalSince1970:)),
            volumeUUID: volume,
            fileID: UInt64(bitPattern: target),
            entryID: entryID,
            uti: row["uti"] as? String
        ), source: [.filenameIndex])
    }

    public func itemCount() async -> Int {
        guard let row = try? database.query(sql: "SELECT COUNT(*) AS count FROM fs_entries;").first,
              let count = row["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    public func upsert(path: String) async throws {
        try await ensureCacheLoaded()
        guard !shouldExclude(path) else { try await remove(path: path); return }
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .typeIdentifierKey, .volumeUUIDStringKey, .parentDirectoryURLKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { try await remove(path: path); return }
        let isDirectory = values.isDirectory == true
        guard isDirectory || values.isRegularFile == true,
              let fileID = normalizeFileID(values.fileResourceIdentifier) else { return }
        let volume = values.volumeUUIDString ?? url.deletingLastPathComponent().path
        let parentURL = values.parentDirectory ?? url.deletingLastPathComponent()
        let parentID = normalizeFileID((try? parentURL.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier) ?? 2
        let name = url.lastPathComponent
        let linkCount = Self.linkCount(at: path)
        try database.execute(sql: "BEGIN IMMEDIATE;")
        do {
            try database.execute(sql: Self.objectUpsertSQL, bindings: [
                volume, Int64(bitPattern: fileID), isDirectory ? 1 : 0,
                isDirectory ? "" : url.pathExtension.lowercased(),
                isDirectory ? 0 : Int64(values.fileSize ?? 0),
                values.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
                values.typeIdentifier ?? NSNull(), linkCount ?? NSNull()
            ])
            try database.execute(sql: Self.entryUpsertSQL, bindings: [
                volume, Int64(bitPattern: parentID), Int64(bitPattern: fileID), name,
                Int64(bitPattern: FuzzyMatcher.characterMask(for: name, caseSensitive: false))
            ])
            try database.execute(sql: "COMMIT;")
        } catch {
            try? database.execute(sql: "ROLLBACK;")
            throw error
        }
        if isDirectory { directoryCache[volume, default: [:]][fileID] = (parentID, name) }
    }

    public func remove(path: String) async throws {
        try await ensureCacheLoaded()
        guard let entry = entryIdentity(for: path) else { return }
        try database.execute(sql: "BEGIN IMMEDIATE;")
        do {
            if entry.isDirectory {
                try deleteEntrySubtree(volumeUUID: entry.volumeUUID, rootTargetID: entry.targetFileID)
            }
            try database.execute(sql: "DELETE FROM fs_entries WHERE entry_id = ?;", bindings: [entry.entryID])
            try cleanupOrphanObjects(volumeUUID: entry.volumeUUID)
            try database.execute(sql: "COMMIT;")
        } catch {
            try? database.execute(sql: "ROLLBACK;")
            throw error
        }
        try await resetCache()
    }

    private struct EntryIdentity {
        let entryID: Int64
        let volumeUUID: String
        let targetFileID: UInt64
        let isDirectory: Bool
    }

    private func entryIdentity(for path: String) -> EntryIdentity? {
        let inputURL = URL(fileURLWithPath: path)
        let parentURL = inputURL.deletingLastPathComponent()
        guard let parentValues = try? parentURL.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeUUIDStringKey]),
              let parentID = normalizeFileID(parentValues.fileResourceIdentifier),
              let volume = parentValues.volumeUUIDString,
              let row = (try? database.query(sql: """
                  SELECT e.entry_id, e.target_file_id, o.is_directory
                  FROM fs_entries e
                  JOIN fs_objects o ON o.volume_uuid = e.volume_uuid AND o.file_id = e.target_file_id
                  WHERE e.volume_uuid = ? AND e.parent_file_id = ? AND e.name = ? LIMIT 1;
                  """, bindings: [volume, Int64(bitPattern: parentID), inputURL.lastPathComponent]))?.first,
              let entryID = row["entry_id"] as? Int64,
              let target = row["target_file_id"] as? Int64,
              let isDirectory = row["is_directory"] as? Int64 else { return nil }
        return EntryIdentity(entryID: entryID, volumeUUID: volume, targetFileID: UInt64(bitPattern: target), isDirectory: isDirectory != 0)
    }

    private func nodeID(forDirectoryPath path: String) -> (volumeUUID: String, fileID: UInt64)? {
        let canonicalPath = Self.canonicalUserPath(path)
        guard let root = configuration.roots.first(where: {
            let canonicalRoot = Self.canonicalUserPath($0.path)
            return canonicalPath == canonicalRoot || canonicalPath.hasPrefix(canonicalRoot + "/") || canonicalRoot.hasPrefix(canonicalPath + "/")
        }) else { return nil }
        let volume = (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? root.path
        let mount = Self.canonicalUserPath(volumeMountPoints[volume] ?? "")
        let relative: String
        if canonicalPath == mount || (mount == "/" && canonicalPath == "/") { return (volume, 2) }
        if mount == "/" { relative = String(canonicalPath.dropFirst()) }
        else if canonicalPath.hasPrefix(mount + "/") { relative = String(canonicalPath.dropFirst(mount.count + 1)) }
        else { return nil }
        var current: UInt64 = 2
        for component in relative.split(separator: "/").map(String.init) {
            guard let next = directoryCache[volume]?.first(where: { $0.value.parentID == current && $0.value.name == component }) else { return nil }
            current = next.key
        }
        return (volume, current)
    }

    private func deleteEntrySubtree(volumeUUID: String, rootTargetID: UInt64) throws {
        try database.execute(sql: """
            WITH RECURSIVE descendants(entry_id, target_file_id) AS (
                SELECT entry_id, target_file_id FROM fs_entries
                WHERE volume_uuid = ? AND parent_file_id = ?
                UNION ALL
                SELECT e.entry_id, e.target_file_id
                FROM fs_entries e JOIN descendants d ON e.parent_file_id = d.target_file_id
                WHERE e.volume_uuid = ?
            )
            DELETE FROM fs_entries WHERE entry_id IN (SELECT entry_id FROM descendants);
            """, bindings: [volumeUUID, Int64(bitPattern: rootTargetID), volumeUUID])
    }

    private func cleanupOrphanObjects(volumeUUID: String) throws {
        try database.execute(sql: """
            DELETE FROM fs_objects
            WHERE volume_uuid = ? AND NOT EXISTS (
                SELECT 1 FROM fs_entries e
                WHERE e.volume_uuid = fs_objects.volume_uuid AND e.target_file_id = fs_objects.file_id
            );
            """, bindings: [volumeUUID])
    }

    public func lastEventID() async -> UInt64? {
        guard let row = try? database.query(sql: "SELECT value FROM metadata WHERE key = 'last_event_id';").first,
              let value = row["value"] as? String else { return nil }
        return UInt64(value)
    }

    public func setLastEventID(_ eventID: UInt64) async {
        try? database.execute(sql: "INSERT OR REPLACE INTO metadata(key, value) VALUES ('last_event_id', ?);", bindings: [String(eventID)])
    }

    private func shouldExclude(_ path: String) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return configuration.excludedPaths.contains { excluded in
            let normalized = URL(fileURLWithPath: excluded).standardizedFileURL.path
            return candidate == normalized || candidate.hasPrefix(normalized + "/")
        }
    }

    private func deleteVolume(_ volumeUUID: String) throws {
        try database.execute(sql: "DELETE FROM fs_entries WHERE volume_uuid = ?;", bindings: [volumeUUID])
        try database.execute(sql: "DELETE FROM fs_objects WHERE volume_uuid = ?;", bindings: [volumeUUID])
    }

    private func pruneDatabase(volumeUUID: String, rootIDs: [UInt64]) throws {
        guard !rootIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: rootIDs.count).joined(separator: ",")
        var bindings: [Any] = rootIDs.map { Int64(bitPattern: $0) }
        bindings += [volumeUUID, volumeUUID, volumeUUID]
        try database.execute(sql: """
            WITH RECURSIVE valid_dirs(fid) AS (
                SELECT file_id FROM fs_objects WHERE file_id IN (\(placeholders)) AND volume_uuid = ?
                UNION
                SELECT e.target_file_id
                FROM fs_entries e
                JOIN fs_objects o ON o.volume_uuid = e.volume_uuid AND o.file_id = e.target_file_id
                JOIN valid_dirs v ON e.parent_file_id = v.fid
                WHERE e.volume_uuid = ? AND o.is_directory = 1
            )
            DELETE FROM fs_entries
            WHERE volume_uuid = ?
              AND parent_file_id NOT IN (SELECT fid FROM valid_dirs)
              AND target_file_id NOT IN (SELECT fid FROM valid_dirs);
            """, bindings: bindings)
    }

    private func pruneExcludedPaths(volumeUUID: String) throws {
        for path in configuration.excludedPaths {
            guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeUUIDStringKey]),
                  values.volumeUUIDString == volumeUUID,
                  let fid = normalizeFileID(values.fileResourceIdentifier) else { continue }
            try deleteEntrySubtree(volumeUUID: volumeUUID, rootTargetID: fid)
            try database.execute(sql: "DELETE FROM fs_entries WHERE volume_uuid = ? AND target_file_id = ?;", bindings: [volumeUUID, Int64(bitPattern: fid)])
        }
    }

    private func scanVolumeRecursively(volumeUUID: String, rootsOnThisVolume: [URL]) throws {
        for root in rootsOnThisVolume {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .typeIdentifierKey, .parentDirectoryURLKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else { continue }
            let context = ScanContext(volumeUUID: volumeUUID, database: database)
            var count = 0
            while let url = enumerator.nextObject() as? URL {
                count += 1
                if count % 256 == 0 { try Task.checkCancellation() }
                if shouldExclude(url.path) { enumerator.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .typeIdentifierKey, .parentDirectoryURLKey]),
                      let fileID = normalizeFileID(values.fileResourceIdentifier) else { continue }
                let isDirectory = values.isDirectory == true
                guard isDirectory || values.isRegularFile == true else { continue }
                let parentURL = values.parentDirectory ?? url.deletingLastPathComponent()
                let parentID = normalizeFileID((try? parentURL.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier) ?? 2
                context.append(
                    fileID: fileID,
                    parentID: parentID,
                    name: url.lastPathComponent,
                    isDirectory: isDirectory,
                    size: isDirectory ? 0 : Int64(values.fileSize ?? 0),
                    modificationDate: values.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
                    uti: values.typeIdentifier,
                    linkCount: Self.linkCount(at: url.path)
                )
                if context.entryRows.count >= 10_000 { context.flush() }
                if let error = context.writeError { throw error }
            }
            context.flush()
            if let error = context.writeError { throw error }
        }
    }

    private static func linkCount(at path: String) -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Int64(info.st_nlink)
    }

    private static func realMountPoint(for path: String) -> String? {
        var buffer = statfs()
        guard statfs(path, &buffer) == 0 else { return nil }
        return withUnsafeBytes(of: &buffer.f_mntonname) {
            guard let base = $0.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            let value = String(cString: base)
            return value.isEmpty ? nil : value
        }
    }

    private static func canonicalUserPath(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if resolved.hasPrefix("/System/Volumes/Data/") { return String(resolved.dropFirst("/System/Volumes/Data".count)) }
        return resolved == "/System/Volumes/Data" ? "/" : resolved
    }

    private func normalizeFileID(_ identifier: Any?) -> UInt64? {
        switch identifier {
        case let number as NSNumber: return number.uint64Value
        case let data as Data:
            return data.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return nil }
                var value: UInt64 = 0
                withUnsafeMutableBytes(of: &value) { destination in
                    destination.copyBytes(from: UnsafeRawBufferPointer(start: base, count: min(source.count, MemoryLayout<UInt64>.size)))
                }
                return value
            }
        default: return nil
        }
    }
}
